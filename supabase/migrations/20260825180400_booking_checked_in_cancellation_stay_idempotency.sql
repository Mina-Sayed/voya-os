-- Voya OS: checked-in cancellation and strict stay-event idempotency.
CREATE OR REPLACE FUNCTION public.request_booking_cancellation(
  p_organization_id uuid,
  p_booking_id uuid,
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
  v_existing_payload_hash text;
  v_snapshot jsonb;
  v_snapshot_hash text;
  v_approval uuid;
  v_now timestamptz;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking cancellation request is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'booking cancellation input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND OR v_booking.status NOT IN ('confirmed', 'checked_in') THEN
    RAISE EXCEPTION 'only a confirmed or checked-in booking can be cancelled through approval' USING ERRCODE = '22023';
  END IF;

  v_snapshot := jsonb_build_object(
    'booking_id', p_booking_id,
    'booking_version', v_booking.version,
    'reason', btrim(p_reason)
  );
  v_snapshot_hash := encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex');
  v_now := clock_timestamp();

  SELECT booking_id, payload_hash
  INTO v_existing_booking_id, v_existing_payload_hash
  FROM public.booking_v1_command_idempotency
  WHERE organization_id = p_organization_id
    AND command_name = 'booking.cancel.request'
    AND idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing_booking_id <> p_booking_id
      OR (v_existing_payload_hash IS NOT NULL AND v_existing_payload_hash <> v_snapshot_hash) THEN
      RAISE EXCEPTION 'cancellation idempotency key payload mismatch' USING ERRCODE = '23505';
    END IF;
    SELECT request.* INTO v_existing
    FROM public.approval_requests AS request
    WHERE request.organization_id = p_organization_id
      AND request.resource_type = 'booking'
      AND request.resource_id = p_booking_id
      AND request.proposed_action = 'booking.cancel'
      AND request.requester_membership_id = v_actor
      AND request.snapshot_hash = v_snapshot_hash
    ORDER BY request.created_at DESC
    LIMIT 1;
    IF FOUND THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'cancellation idempotency key payload mismatch' USING ERRCODE = '23505';
  END IF;

  UPDATE public.approval_requests
  SET status = 'expired', updated_at = v_now
  WHERE organization_id = p_organization_id
    AND resource_type = 'booking'
    AND resource_id = p_booking_id
    AND proposed_action = 'booking.cancel'
    AND status = 'pending'
    AND expires_at IS NOT NULL
    AND expires_at <= v_now;

  SELECT request.* INTO v_existing
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.resource_type = 'booking'
    AND request.resource_id = p_booking_id
    AND request.proposed_action = 'booking.cancel'
    AND request.status = 'pending'
    AND (request.expires_at IS NULL OR request.expires_at > v_now)
  ORDER BY request.created_at DESC
  LIMIT 1;
  IF FOUND THEN
    IF v_existing.snapshot_hash = v_snapshot_hash
      AND v_existing.requester_membership_id = v_actor THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'another booking cancellation is already awaiting approval' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.booking_v1_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id, payload_hash
  ) VALUES (
    p_organization_id, 'booking.cancel.request', btrim(p_idempotency_key),
    p_booking_id, v_snapshot_hash
  );

  INSERT INTO public.approval_requests (
    organization_id, resource_type, resource_id, proposed_action, proposal_snapshot,
    snapshot_hash, requester_membership_id, expires_at
  ) VALUES (
    p_organization_id, 'booking', p_booking_id, 'booking.cancel', v_snapshot,
    v_snapshot_hash, v_actor, v_now + interval '24 hours'
  ) RETURNING id INTO v_approval;

  INSERT INTO public.notifications (
    organization_id, recipient_membership_id, category, title, body,
    resource_type, resource_id, dedupe_key
  )
  SELECT p_organization_id, membership.id, 'approval', 'إلغاء حجز يحتاج اعتمادًا',
    'يوجد طلب إلغاء حجز ينتظر مراجعة مستقلة.', 'booking', p_booking_id,
    'booking-cancel-approval:' || v_approval::text || ':' || membership.id::text
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager')
    AND membership.id <> v_actor;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.cancellation_requested', 'booking',
    p_booking_id, 'success', p_request_id,
    jsonb_build_object('approval_request_id', v_approval, 'reason', btrim(p_reason))
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'booking.cancellation.requested', 1,
    'booking-cancellation:' || v_approval::text,
    jsonb_build_object('approval_request_id', v_approval, 'booking_id', p_booking_id)
  );
  RETURN v_approval;
END;
$$;

CREATE OR REPLACE FUNCTION public.execute_booking_cancellation(
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
  v_existing_booking_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking cancellation execution is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'cancellation execution idempotency key is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT booking_id INTO v_existing_booking_id
  FROM public.booking_v1_command_idempotency
  WHERE organization_id = p_organization_id
    AND command_name = 'booking.cancel.execute'
    AND idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing_booking_id <> p_booking_id THEN
      RAISE EXCEPTION 'cancellation execution idempotency key was reused' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND OR v_booking.status NOT IN ('confirmed', 'checked_in') THEN
    RAISE EXCEPTION 'booking is not cancellable' USING ERRCODE = '22023';
  END IF;

  SELECT request.* INTO v_approval
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.resource_type = 'booking'
    AND request.resource_id = p_booking_id
    AND request.proposed_action = 'booking.cancel'
    AND request.status = 'approved'
  ORDER BY request.created_at DESC
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'approved cancellation is required' USING ERRCODE = '42501';
  END IF;
  IF v_approval.requester_membership_id = v_actor THEN
    RAISE EXCEPTION 'requester cannot execute their own cancellation' USING ERRCODE = '42501';
  END IF;
  v_now := clock_timestamp();
  IF v_approval.expires_at IS NOT NULL AND v_approval.expires_at <= v_now THEN
    RAISE EXCEPTION 'cancellation approval is expired' USING ERRCODE = '42501';
  END IF;

  v_snapshot := jsonb_build_object(
    'booking_id', p_booking_id,
    'booking_version', v_booking.version,
    'reason', v_approval.proposal_snapshot->>'reason'
  );
  IF v_approval.proposal_snapshot <> v_snapshot
    OR v_approval.snapshot_hash <> encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'cancellation snapshot is invalid' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.booking_v1_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id
  ) VALUES (
    p_organization_id, 'booking.cancel.execute', btrim(p_idempotency_key), p_booking_id
  );

  UPDATE public.bookings
  SET status = 'cancelled', idempotency_key = NULL, version = version + 1
  WHERE organization_id = p_organization_id AND id = p_booking_id;

  UPDATE public.approval_requests
  SET status = 'executed', executed_at = v_now, updated_at = v_now
  WHERE organization_id = p_organization_id AND id = v_approval.id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, reason_code, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.cancelled', 'booking', p_booking_id,
    'success', p_request_id, 'approved',
    jsonb_build_object(
      'approval_request_id', v_approval.id,
      'reason', v_approval.proposal_snapshot->>'reason'
    )
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'booking.cancelled', 1,
    'booking-cancelled:' || p_booking_id::text,
    jsonb_build_object('booking_id', p_booking_id, 'approval_request_id', v_approval.id)
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_commercial_booking_stay_event(
  p_organization_id uuid,
  p_booking_id uuid,
  p_event_type text,
  p_notes text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
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
  v_existing public.booking_stay_events%ROWTYPE;
  v_id uuid;
  v_notes text;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'stay event is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_event_type IS NULL OR p_event_type NOT IN ('check_in', 'check_out')
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160
    OR (p_notes IS NOT NULL AND char_length(btrim(p_notes)) NOT BETWEEN 1 AND 2000) THEN
    RAISE EXCEPTION 'stay event input is invalid' USING ERRCODE = '22023';
  END IF;
  v_notes := NULLIF(btrim(p_notes), '');

  SELECT event.* INTO v_existing
  FROM public.booking_stay_events AS event
  WHERE event.organization_id = p_organization_id
    AND event.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.booking_id <> p_booking_id
      OR v_existing.event_type <> p_event_type
      OR v_existing.notes IS DISTINCT FROM v_notes THEN
      RAISE EXCEPTION 'stay-event idempotency key payload mismatch' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND
    OR (p_event_type = 'check_in' AND v_booking.status <> 'confirmed')
    OR (p_event_type = 'check_out' AND v_booking.status <> 'checked_in') THEN
    RAISE EXCEPTION 'booking is not ready for this stay event' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.booking_stay_events (
    organization_id, booking_id, event_type, notes, actor_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, p_booking_id, p_event_type, v_notes, v_actor,
    btrim(p_idempotency_key)
  ) RETURNING id INTO v_id;

  UPDATE public.bookings
  SET status = CASE WHEN p_event_type = 'check_in' THEN 'checked_in' ELSE 'checked_out' END,
      version = version + 1
  WHERE organization_id = p_organization_id AND id = p_booking_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.' || p_event_type, 'booking',
    p_booking_id, 'success', p_request_id,
    jsonb_build_object('event_id', v_id, 'notes', v_notes)
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'booking.' || p_event_type, 1,
    'booking-commercial-stay:' || v_id::text,
    jsonb_build_object('booking_id', p_booking_id, 'event_id', v_id)
  );
  RETURN v_id;
END;
$$;
