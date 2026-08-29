-- Finalize booking amendment review boundaries discovered during PR #10 review.
-- Keep mutable readiness checks out of idempotent replay, expose a complete
-- normalized safe proposal summary, and reject stale booking-change snapshots
-- before a checker records an approval decision.

CREATE OR REPLACE FUNCTION public.list_approval_requests_v2(
  p_organization_id uuid,
  p_limit integer DEFAULT 50
)
RETURNS TABLE (
  id uuid,
  resource_type text,
  resource_id uuid,
  proposed_action text,
  status text,
  expires_at timestamptz,
  created_at timestamptz,
  proposal_summary jsonb,
  requester_display_name text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_membership_id uuid;
  v_role text;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'approval request limit is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id, membership.role INTO v_membership_id, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';

  IF v_membership_id IS NULL OR v_role = 'viewer' THEN
    RAISE EXCEPTION 'approval request read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT request.id,
    request.resource_type,
    request.resource_id,
    request.proposed_action,
    request.status,
    request.expires_at,
    request.created_at,
    CASE request.proposed_action
      WHEN 'booking.confirm' THEN jsonb_build_object(
        'checkIn', request.proposal_snapshot->>'check_in',
        'checkOut', request.proposal_snapshot->>'check_out',
        'amountMinor', request.proposal_snapshot->>'agreed_total_amount_minor',
        'currency', request.proposal_snapshot->>'currency',
        'propertyId', request.proposal_snapshot->>'property_id',
        'clientId', request.proposal_snapshot->>'client_id'
      )
      WHEN 'booking.amend' THEN jsonb_build_object(
        'checkIn', request.proposal_snapshot->>'check_in',
        'checkOut', request.proposal_snapshot->>'check_out',
        'amountMinor', request.proposal_snapshot->>'agreed_total_amount_minor',
        'currency', request.proposal_snapshot->>'currency',
        'reason', request.proposal_snapshot->>'reason',
        'propertyId', request.proposal_snapshot->>'property_id',
        'clientId', request.proposal_snapshot->>'client_id',
        'propertyLabel', (
          SELECT property_record.code || ' — ' || property_record.name
          FROM public.properties AS property_record
          WHERE property_record.organization_id = request.organization_id
            AND property_record.id = (request.proposal_snapshot->>'property_id')::uuid
        ),
        'clientLabel', (
          SELECT client_record.display_name
          FROM public.clients AS client_record
          WHERE client_record.organization_id = request.organization_id
            AND client_record.id = (request.proposal_snapshot->>'client_id')::uuid
        )
      )
      WHEN 'booking.cancel' THEN jsonb_build_object(
        'reason', request.proposal_snapshot->>'reason'
      )
      ELSE '{}'::jsonb
    END,
    profile.display_name
  FROM public.approval_requests AS request
  JOIN public.organization_memberships AS requester
    ON requester.organization_id = request.organization_id
   AND requester.id = request.requester_membership_id
  LEFT JOIN public.profiles AS profile ON profile.id = requester.user_id
  WHERE request.organization_id = p_organization_id
    AND (v_role IN ('owner', 'manager') OR request.requester_membership_id = v_membership_id)
  ORDER BY request.created_at DESC, request.id DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.list_approval_requests_v2(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_approval_requests_v2(uuid, integer) TO authenticated;

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
  v_approval uuid;
  v_existing_approval uuid;
  v_existing_request public.approval_requests%ROWTYPE;
  v_snapshot jsonb;
  v_amount bigint;
  v_org_currency text;
  v_key text := btrim(p_idempotency_key);
  v_inserted_count integer;
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
    OR p_idempotency_key IS NULL OR char_length(v_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'booking amendment input is invalid' USING ERRCODE = '22023';
  END IF;

  BEGIN
    v_amount := p_amount_minor::bigint;
  EXCEPTION WHEN numeric_value_out_of_range THEN
    RAISE EXCEPTION 'booking amendment amount is out of range' USING ERRCODE = '22003';
  END;

  -- Replay a committed command result before re-evaluating mutable readiness,
  -- resource activity, or the current booking version. The stored immutable
  -- proposal is compared directly with the submitted payload so changed input
  -- cannot reuse the key while a genuine lost-response retry remains stable.
  SELECT idempotency.result_id INTO v_existing_approval
  FROM public.booking_v1_command_idempotency AS idempotency
  WHERE idempotency.organization_id = p_organization_id
    AND idempotency.command_name = 'booking.amend.request'
    AND idempotency.idempotency_key = v_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_approval IS NULL THEN
      RAISE EXCEPTION 'idempotency key has no replayable amendment result' USING ERRCODE = '23505';
    END IF;

    SELECT request.* INTO v_existing_request
    FROM public.approval_requests AS request
    WHERE request.organization_id = p_organization_id
      AND request.id = v_existing_approval;

    IF NOT FOUND
      OR v_existing_request.proposed_action <> 'booking.amend'
      OR v_existing_request.resource_id <> p_booking_id
      OR v_existing_request.requester_membership_id <> v_actor
      OR (v_existing_request.proposal_snapshot->>'property_id')::uuid IS DISTINCT FROM p_property_id
      OR (v_existing_request.proposal_snapshot->>'client_id')::uuid IS DISTINCT FROM p_client_id
      OR (v_existing_request.proposal_snapshot->>'check_in')::date IS DISTINCT FROM p_check_in
      OR (v_existing_request.proposal_snapshot->>'check_out')::date IS DISTINCT FROM p_check_out
      OR (v_existing_request.proposal_snapshot->>'agreed_total_amount_minor')::bigint IS DISTINCT FROM v_amount
      OR v_existing_request.proposal_snapshot->>'currency' IS DISTINCT FROM p_currency
      OR v_existing_request.proposal_snapshot->>'reason' IS DISTINCT FROM btrim(p_reason)
      OR v_existing_request.snapshot_hash <> encode(extensions.digest(v_existing_request.proposal_snapshot::text, 'sha256'), 'hex') THEN
      RAISE EXCEPTION 'idempotency key belongs to a different amendment' USING ERRCODE = '23505';
    END IF;

    RETURN v_existing_approval;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.organization_memberships AS checker
    WHERE checker.organization_id = p_organization_id
      AND checker.status = 'active'
      AND checker.role IN ('owner', 'manager')
      AND checker.id <> v_actor
  ) THEN
    RAISE EXCEPTION 'APPROVAL_NOT_OPERATIONALLY_READY' USING ERRCODE = '42501';
  END IF;

  SELECT organization.default_currency INTO v_org_currency
  FROM public.organizations AS organization
  WHERE organization.id = p_organization_id
    AND organization.status = 'active';
  IF v_org_currency IS NULL THEN
    RAISE EXCEPTION 'organization is invalid' USING ERRCODE = '23503';
  END IF;
  IF p_currency <> v_org_currency THEN
    RAISE EXCEPTION 'booking currency must match organization currency' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.properties
    WHERE organization_id = p_organization_id
      AND id = p_property_id
      AND status = 'active'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.clients
    WHERE organization_id = p_organization_id
      AND id = p_client_id
      AND archived_at IS NULL
  ) THEN
    RAISE EXCEPTION 'amendment property or client is invalid' USING ERRCODE = '23503';
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'confirmed' THEN
    RAISE EXCEPTION 'only a confirmed booking can be amended' USING ERRCODE = '22023';
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

  INSERT INTO public.booking_v1_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id
  ) VALUES (
    p_organization_id, 'booking.amend.request', v_key, p_booking_id
  )
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  IF v_inserted_count = 0 THEN
    SELECT idempotency.result_id INTO v_existing_approval
    FROM public.booking_v1_command_idempotency AS idempotency
    WHERE idempotency.organization_id = p_organization_id
      AND idempotency.command_name = 'booking.amend.request'
      AND idempotency.idempotency_key = v_key
    FOR UPDATE;

    IF v_existing_approval IS NULL THEN
      RAISE EXCEPTION 'idempotency key has no replayable amendment result' USING ERRCODE = '23505';
    END IF;

    SELECT request.* INTO v_existing_request
    FROM public.approval_requests AS request
    WHERE request.organization_id = p_organization_id
      AND request.id = v_existing_approval;

    IF NOT FOUND
      OR v_existing_request.proposed_action <> 'booking.amend'
      OR v_existing_request.resource_id <> p_booking_id
      OR v_existing_request.requester_membership_id <> v_actor
      OR (v_existing_request.proposal_snapshot->>'property_id')::uuid IS DISTINCT FROM p_property_id
      OR (v_existing_request.proposal_snapshot->>'client_id')::uuid IS DISTINCT FROM p_client_id
      OR (v_existing_request.proposal_snapshot->>'check_in')::date IS DISTINCT FROM p_check_in
      OR (v_existing_request.proposal_snapshot->>'check_out')::date IS DISTINCT FROM p_check_out
      OR (v_existing_request.proposal_snapshot->>'agreed_total_amount_minor')::bigint IS DISTINCT FROM v_amount
      OR v_existing_request.proposal_snapshot->>'currency' IS DISTINCT FROM p_currency
      OR v_existing_request.proposal_snapshot->>'reason' IS DISTINCT FROM btrim(p_reason)
      OR v_existing_request.snapshot_hash <> encode(extensions.digest(v_existing_request.proposal_snapshot::text, 'sha256'), 'hex') THEN
      RAISE EXCEPTION 'idempotency key belongs to a different amendment' USING ERRCODE = '23505';
    END IF;

    RETURN v_existing_approval;
  END IF;

  INSERT INTO public.approval_requests (
    organization_id,
    resource_type,
    resource_id,
    proposed_action,
    proposal_snapshot,
    snapshot_hash,
    requester_membership_id,
    expires_at
  ) VALUES (
    p_organization_id,
    'booking',
    p_booking_id,
    'booking.amend',
    v_snapshot,
    encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'),
    v_actor,
    clock_timestamp() + interval '24 hours'
  ) RETURNING id INTO v_approval;

  UPDATE public.booking_v1_command_idempotency
  SET result_id = v_approval
  WHERE organization_id = p_organization_id
    AND command_name = 'booking.amend.request'
    AND idempotency_key = v_key;

  INSERT INTO public.notifications (
    organization_id,
    recipient_membership_id,
    category,
    title,
    body,
    resource_type,
    resource_id,
    dedupe_key
  )
  SELECT p_organization_id,
    membership.id,
    'approval',
    'تعديل حجز يحتاج اعتمادًا',
    'يوجد اقتراح تعديل حجز ينتظر مراجعة مستقلة.',
    'booking',
    p_booking_id,
    'booking-amendment-approval:' || v_approval::text || ':' || membership.id::text
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager')
    AND membership.id <> v_actor;

  INSERT INTO public.audit_events (
    organization_id,
    actor_type,
    actor_membership_id,
    action,
    resource_type,
    resource_id,
    outcome,
    request_id,
    after_delta
  ) VALUES (
    p_organization_id,
    'user',
    v_actor,
    'booking.amendment_requested',
    'booking',
    p_booking_id,
    'success',
    p_request_id,
    jsonb_build_object('approval_request_id', v_approval, 'reason', btrim(p_reason))
  );

  INSERT INTO public.outbox_events (
    organization_id,
    event_type,
    schema_version,
    dedupe_key,
    payload
  ) VALUES (
    p_organization_id,
    'booking.amendment.requested',
    1,
    'booking-amendment:' || v_approval::text,
    jsonb_build_object('approval_request_id', v_approval, 'booking_id', p_booking_id)
  );

  RETURN v_approval;
END;
$$;

REVOKE ALL ON FUNCTION public.request_booking_amendment(uuid,uuid,uuid,uuid,date,date,text,text,text,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_booking_amendment(uuid,uuid,uuid,uuid,date,date,text,text,text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.decide_booking_approval(
  p_organization_id uuid,
  p_approval_request_id uuid,
  p_decision text,
  p_reason text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_booking_id uuid;
  v_request public.approval_requests%ROWTYPE;
  v_booking public.bookings%ROWTYPE;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking approval decision is not permitted' USING ERRCODE = '42501';
  END IF;

  IF p_decision IS NULL
    OR p_decision NOT IN ('approved', 'rejected')
    OR p_reason IS NULL
    OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'approval decision is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT request.resource_id INTO v_booking_id
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_approval_request_id
    AND request.resource_type = 'booking'
    AND request.proposed_action IN ('booking.confirm', 'booking.amend', 'booking.cancel');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'approval request is no longer actionable' USING ERRCODE = '22023';
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.id = v_booking_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking is no longer awaiting approval' USING ERRCODE = '22023';
  END IF;

  SELECT request.* INTO v_request
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_approval_request_id
    AND request.resource_type = 'booking'
    AND request.proposed_action IN ('booking.confirm', 'booking.amend', 'booking.cancel')
  FOR UPDATE;

  IF NOT FOUND
    OR v_request.resource_id <> v_booking.id
    OR v_request.status <> 'pending'
    OR (v_request.expires_at IS NOT NULL AND v_request.expires_at <= timezone('utc', now())) THEN
    RAISE EXCEPTION 'approval request is no longer actionable' USING ERRCODE = '22023';
  END IF;

  IF v_request.requester_membership_id = v_actor THEN
    RAISE EXCEPTION 'requester cannot approve their own booking change' USING ERRCODE = '42501';
  END IF;

  IF (v_request.proposed_action = 'booking.confirm' AND v_booking.status <> 'pending_approval')
    OR (v_request.proposed_action IN ('booking.amend', 'booking.cancel') AND v_booking.status <> 'confirmed') THEN
    RAISE EXCEPTION 'booking is no longer in the required approval state' USING ERRCODE = '22023';
  END IF;

  IF v_request.proposed_action IN ('booking.amend', 'booking.cancel')
    AND (v_request.proposal_snapshot->>'booking_version')::integer IS DISTINCT FROM v_booking.version THEN
    RAISE EXCEPTION 'approval request snapshot is stale' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.approval_decisions (
    organization_id,
    approval_request_id,
    approver_membership_id,
    decision,
    reason
  ) VALUES (
    p_organization_id,
    p_approval_request_id,
    v_actor,
    p_decision,
    btrim(p_reason)
  );

  UPDATE public.approval_requests
  SET status = p_decision,
      updated_at = timezone('utc', now())
  WHERE organization_id = p_organization_id
    AND id = p_approval_request_id;

  IF p_decision = 'rejected' AND v_request.proposed_action = 'booking.confirm' THEN
    UPDATE public.bookings
    SET status = 'draft'
    WHERE organization_id = p_organization_id
      AND id = v_request.resource_id;
  END IF;

  INSERT INTO public.audit_events (
    organization_id,
    actor_type,
    actor_membership_id,
    action,
    resource_type,
    resource_id,
    outcome,
    request_id,
    after_delta
  ) VALUES (
    p_organization_id,
    'user',
    v_actor,
    'booking.approval.' || p_decision,
    'booking',
    v_request.resource_id,
    'success',
    p_request_id,
    jsonb_build_object(
      'approval_request_id', p_approval_request_id,
      'proposed_action', v_request.proposed_action,
      'reason', btrim(p_reason)
    )
  );

  INSERT INTO public.outbox_events (
    organization_id,
    event_type,
    schema_version,
    dedupe_key,
    payload
  ) VALUES (
    p_organization_id,
    'booking.approval.' || p_decision,
    1,
    'booking-approval-decision:' || p_approval_request_id::text || ':' || p_decision,
    jsonb_build_object(
      'approval_request_id', p_approval_request_id,
      'booking_id', v_request.resource_id,
      'proposed_action', v_request.proposed_action
    )
  );

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.decide_booking_approval(uuid,uuid,text,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decide_booking_approval(uuid,uuid,text,text,uuid) TO authenticated;
