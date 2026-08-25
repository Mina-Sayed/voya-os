-- Voya OS: checked-in booking amendment workflow.
CREATE OR REPLACE FUNCTION public.request_booking_amendment(
  p_organization_id uuid,
  p_booking_id uuid,
  p_property_id uuid,
  p_client_id uuid,
  p_check_in date,
  p_check_out date,
  p_amount_minor text,
  p_currency text,
  p_reason text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_booking public.bookings%ROWTYPE;
  v_existing public.approval_requests%ROWTYPE;
  v_existing_booking_id uuid;
  v_approval uuid;
  v_snapshot jsonb;
  v_snapshot_hash text;
  v_amount bigint;
  v_org_currency text;
  v_now timestamptz;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking amendment request is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_check_in IS NULL OR p_check_out IS NULL OR p_check_in >= p_check_out
    OR p_amount_minor IS NULL OR p_amount_minor !~ '^[0-9]{1,19}$'
    OR p_currency IS NULL OR p_currency !~ '^[A-Z]{3}$'
    OR p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'booking amendment input is invalid' USING ERRCODE = '22023';
  END IF;

  v_amount := p_amount_minor::bigint;
  SELECT organization.default_currency INTO v_org_currency
  FROM public.organizations AS organization
  WHERE organization.id = p_organization_id AND organization.status = 'active';
  IF p_currency <> v_org_currency THEN
    RAISE EXCEPTION 'booking currency must match organization currency' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM public.properties
      WHERE organization_id = p_organization_id AND id = p_property_id AND status = 'active'
    ) OR NOT EXISTS (
      SELECT 1 FROM public.clients
      WHERE organization_id = p_organization_id AND id = p_client_id AND archived_at IS NULL
    ) THEN
    RAISE EXCEPTION 'amendment property or client is invalid' USING ERRCODE = '23503';
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND OR v_booking.status NOT IN ('confirmed', 'checked_in') THEN
    RAISE EXCEPTION 'only a confirmed or checked-in booking can be amended' USING ERRCODE = '22023';
  END IF;
  IF v_booking.status = 'checked_in'
    AND (p_property_id <> v_booking.property_id
      OR p_client_id <> v_booking.client_id
      OR p_check_in <> v_booking.check_in) THEN
    RAISE EXCEPTION 'checked-in booking arrival identity is immutable' USING ERRCODE = '22023';
  END IF;

  v_snapshot := jsonb_build_object(
    'booking_id', v_booking.id,
    'booking_version', v_booking.version,
    'property_id', p_property_id,
    'client_id', p_client_id,
    'check_in', p_check_in,
    'check_out', p_check_out,
    'agreed_total_amount_minor', v_amount,
    'currency', p_currency,
    'reason', btrim(p_reason)
  );
  v_snapshot_hash := encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex');
  v_now := clock_timestamp();

  SELECT booking_id INTO v_existing_booking_id
  FROM public.booking_v1_command_idempotency
  WHERE organization_id = p_organization_id
    AND command_name = 'booking.amend.request'
    AND idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing_booking_id <> p_booking_id THEN
      RAISE EXCEPTION 'amendment idempotency key was reused' USING ERRCODE = '23505';
    END IF;
    SELECT request.* INTO v_existing
    FROM public.approval_requests AS request
    WHERE request.organization_id = p_organization_id
      AND request.resource_type = 'booking'
      AND request.resource_id = p_booking_id
      AND request.proposed_action = 'booking.amend'
      AND request.requester_membership_id = v_actor
      AND request.snapshot_hash = v_snapshot_hash
    ORDER BY request.created_at DESC
    LIMIT 1;
    IF FOUND THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'amendment idempotency key payload mismatch' USING ERRCODE = '23505';
  END IF;

  UPDATE public.approval_requests
  SET status = 'expired', updated_at = v_now
  WHERE organization_id = p_organization_id
    AND resource_type = 'booking'
    AND resource_id = p_booking_id
    AND proposed_action = 'booking.amend'
    AND status = 'pending'
    AND expires_at IS NOT NULL
    AND expires_at <= v_now;

  SELECT request.* INTO v_existing
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.resource_type = 'booking'
    AND request.resource_id = p_booking_id
    AND request.proposed_action = 'booking.amend'
    AND request.status = 'pending'
    AND (request.expires_at IS NULL OR request.expires_at > v_now)
  ORDER BY request.created_at DESC
  LIMIT 1;
  IF FOUND THEN
    IF v_existing.snapshot_hash = v_snapshot_hash AND v_existing.requester_membership_id = v_actor THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'another booking amendment is already awaiting approval' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.booking_v1_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id
  ) VALUES (
    p_organization_id, 'booking.amend.request', btrim(p_idempotency_key), p_booking_id
  );

  INSERT INTO public.approval_requests (
    organization_id, resource_type, resource_id, proposed_action, proposal_snapshot,
    snapshot_hash, requester_membership_id, expires_at
  ) VALUES (
    p_organization_id, 'booking', p_booking_id, 'booking.amend', v_snapshot,
    v_snapshot_hash, v_actor, v_now + interval '24 hours'
  ) RETURNING id INTO v_approval;

  INSERT INTO public.notifications (
    organization_id, recipient_membership_id, category, title, body,
    resource_type, resource_id, dedupe_key
  )
  SELECT p_organization_id, membership.id, 'approval', 'تعديل حجز يحتاج اعتمادًا',
    'يوجد اقتراح تعديل حجز ينتظر مراجعة مستقلة.', 'booking', p_booking_id,
    'booking-amendment-approval:' || v_approval::text || ':' || membership.id::text
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager')
    AND membership.id <> v_actor;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.amendment_requested', 'booking',
    p_booking_id, 'success', p_request_id,
    jsonb_build_object('approval_request_id', v_approval, 'reason', btrim(p_reason))
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'booking.amendment.requested', 1,
    'booking-amendment:' || v_approval::text,
    jsonb_build_object('approval_request_id', v_approval, 'booking_id', p_booking_id)
  );
  RETURN v_approval;
END;
$$;

CREATE OR REPLACE FUNCTION public.execute_booking_amendment(
  p_organization_id uuid,
  p_booking_id uuid,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_booking public.bookings%ROWTYPE;
  v_approval public.approval_requests%ROWTYPE;
  v_snapshot jsonb;
  v_now timestamptz;
  v_new_property uuid;
  v_new_client uuid;
  v_new_amount bigint;
  v_new_currency text;
  v_new_check_in date;
  v_new_check_out date;
  v_existing_booking_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking amendment execution is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'amendment execution idempotency key is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT booking_id INTO v_existing_booking_id
  FROM public.booking_v1_command_idempotency
  WHERE organization_id = p_organization_id
    AND command_name = 'booking.amend.execute'
    AND idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing_booking_id <> p_booking_id THEN
      RAISE EXCEPTION 'amendment execution idempotency key was reused' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND OR v_booking.status NOT IN ('confirmed', 'checked_in') THEN
    RAISE EXCEPTION 'booking is not amendable' USING ERRCODE = '22023';
  END IF;

  SELECT request.* INTO v_approval
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.resource_type = 'booking'
    AND request.resource_id = p_booking_id
    AND request.proposed_action = 'booking.amend'
    AND request.status = 'approved'
  ORDER BY request.created_at DESC
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'approved amendment is required' USING ERRCODE = '42501';
  END IF;
  IF v_approval.requester_membership_id = v_actor THEN
    RAISE EXCEPTION 'requester cannot execute their own amendment' USING ERRCODE = '42501';
  END IF;
  v_now := clock_timestamp();
  IF v_approval.expires_at IS NOT NULL AND v_approval.expires_at <= v_now THEN
    RAISE EXCEPTION 'amendment approval is expired' USING ERRCODE = '42501';
  END IF;

  v_new_property := (v_approval.proposal_snapshot->>'property_id')::uuid;
  v_new_client := (v_approval.proposal_snapshot->>'client_id')::uuid;
  v_new_check_in := (v_approval.proposal_snapshot->>'check_in')::date;
  v_new_check_out := (v_approval.proposal_snapshot->>'check_out')::date;
  v_new_amount := (v_approval.proposal_snapshot->>'agreed_total_amount_minor')::bigint;
  v_new_currency := v_approval.proposal_snapshot->>'currency';
  v_snapshot := jsonb_build_object(
    'booking_id', v_booking.id,
    'booking_version', v_booking.version,
    'property_id', v_new_property,
    'client_id', v_new_client,
    'check_in', v_new_check_in,
    'check_out', v_new_check_out,
    'agreed_total_amount_minor', v_new_amount,
    'currency', v_new_currency,
    'reason', v_approval.proposal_snapshot->>'reason'
  );

  IF v_approval.proposal_snapshot <> v_snapshot
    OR v_approval.snapshot_hash <> encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'amendment snapshot is invalid' USING ERRCODE = '22023';
  END IF;
  IF (v_approval.proposal_snapshot->>'booking_version')::integer <> v_booking.version THEN
    RAISE EXCEPTION 'booking version is stale' USING ERRCODE = '22023';
  END IF;
  IF v_booking.status = 'checked_in'
    AND (v_new_property <> v_booking.property_id
      OR v_new_client <> v_booking.client_id
      OR v_new_check_in <> v_booking.check_in) THEN
    RAISE EXCEPTION 'checked-in booking arrival identity is immutable' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM public.properties
      WHERE organization_id = p_organization_id AND id = v_new_property AND status = 'active'
    ) OR NOT EXISTS (
      SELECT 1 FROM public.clients
      WHERE organization_id = p_organization_id AND id = v_new_client AND archived_at IS NULL
    ) THEN
    RAISE EXCEPTION 'amendment property or client is invalid' USING ERRCODE = '23503';
  END IF;

  INSERT INTO public.booking_v1_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id
  ) VALUES (
    p_organization_id, 'booking.amend.execute', btrim(p_idempotency_key), p_booking_id
  );

  UPDATE public.bookings
  SET property_id = v_new_property,
      client_id = v_new_client,
      check_in = v_new_check_in,
      check_out = v_new_check_out,
      agreed_total_amount_minor = v_new_amount,
      currency = v_new_currency,
      commercial_completion_status = 'complete',
      version = version + 1
  WHERE organization_id = p_organization_id AND id = p_booking_id;

  UPDATE public.approval_requests
  SET status = 'executed', executed_at = v_now, updated_at = v_now
  WHERE organization_id = p_organization_id AND id = v_approval.id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.amended', 'booking', p_booking_id,
    'success', p_request_id,
    jsonb_build_object(
      'approval_request_id', v_approval.id,
      'booking_version', v_booking.version,
      'reason', v_approval.proposal_snapshot->>'reason'
    )
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'booking.amended', 1,
    'booking-amended:' || p_booking_id::text || ':' || v_booking.version::text,
    jsonb_build_object('booking_id', p_booking_id, 'approval_request_id', v_approval.id)
  );
  RETURN true;
END;
$$;
