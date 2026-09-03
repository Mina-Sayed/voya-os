-- Voya OS: booking cancellation replay guards (K-043 hardening).
--
-- Extends the cancellation commands wired by the booking amendment/cancel UI
-- with the same idempotency-replay contract the amendment flows already
-- enforce (see 20260826010000_finalize_booking_amendment_review_boundaries.sql):
-- replaying a committed command with the same (organization, command, key)
-- and the same payload returns the stored result without duplicating
-- approvals, audit evidence, or outbox events, while the same key with
-- different data raises 23505. Rows written before this migration carry no
-- result_id, so a replay against them fails closed with 23505.
--
-- Expired cancellation approvals now raise 22023 (invalid: no valid approval
-- to execute) instead of 42501 so the workspace maps expiry to its invalid
-- path rather than to a permission denial. Role gates, maker-checker,
-- occupancy, and audit/outbox behavior are otherwise unchanged.

CREATE OR REPLACE FUNCTION public.cancel_booking_draft(
  p_organization_id uuid,
  p_booking_id uuid,
  p_reason text,
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
  v_key text := btrim(p_idempotency_key);
  v_existing_booking uuid;
  v_inserted_count integer;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'draft cancellation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000
    OR p_idempotency_key IS NULL OR char_length(v_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'draft cancellation input is invalid' USING ERRCODE = '22023';
  END IF;

  -- Replay a committed cancellation before touching the booking row: a lost
  -- response retry with the same key returns success without duplicating
  -- audit evidence.
  SELECT idempotency.booking_id INTO v_existing_booking
  FROM public.booking_v1_command_idempotency AS idempotency
  WHERE idempotency.organization_id = p_organization_id
    AND idempotency.command_name = 'booking.cancel.draft'
    AND idempotency.idempotency_key = v_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_booking IS DISTINCT FROM p_booking_id THEN
      RAISE EXCEPTION 'idempotency key belongs to a different draft cancellation' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'draft' THEN RAISE EXCEPTION 'only a draft booking can be cancelled directly' USING ERRCODE = '22023'; END IF;

  INSERT INTO public.booking_v1_command_idempotency (organization_id, command_name, idempotency_key, booking_id)
  VALUES (p_organization_id, 'booking.cancel.draft', v_key, p_booking_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  IF v_inserted_count = 0 THEN
    SELECT idempotency.booking_id INTO v_existing_booking
    FROM public.booking_v1_command_idempotency AS idempotency
    WHERE idempotency.organization_id = p_organization_id
      AND idempotency.command_name = 'booking.cancel.draft'
      AND idempotency.idempotency_key = v_key
    FOR UPDATE;

    IF NOT FOUND OR v_existing_booking IS DISTINCT FROM p_booking_id THEN
      RAISE EXCEPTION 'idempotency key belongs to a different draft cancellation' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  UPDATE public.bookings SET status = 'cancelled', idempotency_key = NULL, version = version + 1 WHERE organization_id = p_organization_id AND id = p_booking_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta) VALUES (p_organization_id, 'user', v_actor, 'booking.draft_cancelled', 'booking', p_booking_id, 'success', p_request_id, 'user_requested', jsonb_build_object('reason', btrim(p_reason)));
  RETURN true;
END;
$$;

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
  v_snapshot jsonb;
  v_approval uuid;
  v_existing_approval uuid;
  v_existing_request public.approval_requests%ROWTYPE;
  v_key text := btrim(p_idempotency_key);
  v_inserted_count integer;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'booking cancellation request is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000
    OR p_idempotency_key IS NULL OR char_length(v_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'booking cancellation input is invalid' USING ERRCODE = '22023'; END IF;

  -- Replay a committed request before re-evaluating mutable readiness. The
  -- stored immutable proposal is compared directly with the submitted payload
  -- so changed input cannot reuse the key while a genuine lost-response retry
  -- returns the original approval instead of opening a duplicate request.
  SELECT idempotency.result_id INTO v_existing_approval
  FROM public.booking_v1_command_idempotency AS idempotency
  WHERE idempotency.organization_id = p_organization_id
    AND idempotency.command_name = 'booking.cancel.request'
    AND idempotency.idempotency_key = v_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_approval IS NULL THEN
      RAISE EXCEPTION 'idempotency key has no replayable cancellation result' USING ERRCODE = '23505';
    END IF;

    SELECT request.* INTO v_existing_request
    FROM public.approval_requests AS request
    WHERE request.organization_id = p_organization_id
      AND request.id = v_existing_approval;

    IF NOT FOUND
      OR v_existing_request.proposed_action <> 'booking.cancel'
      OR v_existing_request.resource_id <> p_booking_id
      OR v_existing_request.requester_membership_id <> v_actor
      OR (v_existing_request.proposal_snapshot->>'booking_id')::uuid IS DISTINCT FROM p_booking_id
      OR v_existing_request.proposal_snapshot->>'reason' IS DISTINCT FROM btrim(p_reason)
      OR v_existing_request.snapshot_hash <> encode(extensions.digest(v_existing_request.proposal_snapshot::text, 'sha256'), 'hex') THEN
      RAISE EXCEPTION 'idempotency key belongs to a different cancellation request' USING ERRCODE = '23505';
    END IF;

    RETURN v_existing_approval;
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'confirmed' THEN RAISE EXCEPTION 'only a confirmed booking can be cancelled through approval' USING ERRCODE = '22023'; END IF;

  INSERT INTO public.booking_v1_command_idempotency (organization_id, command_name, idempotency_key, booking_id)
  VALUES (p_organization_id, 'booking.cancel.request', v_key, p_booking_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  IF v_inserted_count = 0 THEN
    SELECT idempotency.result_id INTO v_existing_approval
    FROM public.booking_v1_command_idempotency AS idempotency
    WHERE idempotency.organization_id = p_organization_id
      AND idempotency.command_name = 'booking.cancel.request'
      AND idempotency.idempotency_key = v_key
    FOR UPDATE;

    IF v_existing_approval IS NULL THEN
      RAISE EXCEPTION 'idempotency key has no replayable cancellation result' USING ERRCODE = '23505';
    END IF;

    SELECT request.* INTO v_existing_request
    FROM public.approval_requests AS request
    WHERE request.organization_id = p_organization_id
      AND request.id = v_existing_approval;

    IF NOT FOUND
      OR v_existing_request.proposed_action <> 'booking.cancel'
      OR v_existing_request.resource_id <> p_booking_id
      OR v_existing_request.requester_membership_id <> v_actor
      OR (v_existing_request.proposal_snapshot->>'booking_id')::uuid IS DISTINCT FROM p_booking_id
      OR v_existing_request.proposal_snapshot->>'reason' IS DISTINCT FROM btrim(p_reason)
      OR v_existing_request.snapshot_hash <> encode(extensions.digest(v_existing_request.proposal_snapshot::text, 'sha256'), 'hex') THEN
      RAISE EXCEPTION 'idempotency key belongs to a different cancellation request' USING ERRCODE = '23505';
    END IF;

    RETURN v_existing_approval;
  END IF;

  v_snapshot := jsonb_build_object('booking_id', p_booking_id, 'booking_version', v_booking.version, 'reason', btrim(p_reason));
  INSERT INTO public.approval_requests (organization_id, resource_type, resource_id, proposed_action, proposal_snapshot, snapshot_hash, requester_membership_id, expires_at) VALUES (p_organization_id, 'booking', p_booking_id, 'booking.cancel', v_snapshot, encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'), v_actor, clock_timestamp() + interval '24 hours') RETURNING id INTO v_approval;

  UPDATE public.booking_v1_command_idempotency
  SET result_id = v_approval
  WHERE organization_id = p_organization_id
    AND command_name = 'booking.cancel.request'
    AND idempotency_key = v_key;

  INSERT INTO public.notifications (organization_id, recipient_membership_id, category, title, body, resource_type, resource_id, dedupe_key)
  SELECT p_organization_id, membership.id, 'approval', 'إلغاء حجز يحتاج اعتمادًا', 'يوجد طلب إلغاء حجز ينتظر مراجعة مستقلة.', 'booking', p_booking_id, 'booking-cancel-approval:' || v_approval::text || ':' || membership.id::text
  FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.status = 'active' AND membership.role IN ('owner', 'manager') AND membership.id <> v_actor;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta) VALUES (p_organization_id, 'user', v_actor, 'booking.cancellation_requested', 'booking', p_booking_id, 'success', p_request_id, jsonb_build_object('approval_request_id', v_approval, 'reason', btrim(p_reason)));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'booking.cancellation.requested', 1, 'booking-cancellation:' || v_approval::text, jsonb_build_object('approval_request_id', v_approval, 'booking_id', p_booking_id));
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
  v_key text := btrim(p_idempotency_key);
  v_existing_booking uuid;
  v_inserted_count integer;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'booking cancellation execution is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_idempotency_key IS NULL OR char_length(v_key) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'cancellation execution idempotency key is invalid' USING ERRCODE = '22023'; END IF;

  -- Replay a committed execution before re-evaluating mutable state so a
  -- lost-response retry reports success instead of failing on the already
  -- cancelled booking.
  SELECT idempotency.booking_id INTO v_existing_booking
  FROM public.booking_v1_command_idempotency AS idempotency
  WHERE idempotency.organization_id = p_organization_id
    AND idempotency.command_name = 'booking.cancel.execute'
    AND idempotency.idempotency_key = v_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_booking IS DISTINCT FROM p_booking_id THEN
      RAISE EXCEPTION 'idempotency key belongs to a different cancellation execution' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'confirmed' THEN RAISE EXCEPTION 'booking is not cancellable' USING ERRCODE = '22023'; END IF;

  INSERT INTO public.booking_v1_command_idempotency (organization_id, command_name, idempotency_key, booking_id)
  VALUES (p_organization_id, 'booking.cancel.execute', v_key, p_booking_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  IF v_inserted_count = 0 THEN
    SELECT idempotency.booking_id INTO v_existing_booking
    FROM public.booking_v1_command_idempotency AS idempotency
    WHERE idempotency.organization_id = p_organization_id
      AND idempotency.command_name = 'booking.cancel.execute'
      AND idempotency.idempotency_key = v_key
    FOR UPDATE;

    IF NOT FOUND OR v_existing_booking IS DISTINCT FROM p_booking_id THEN
      RAISE EXCEPTION 'idempotency key belongs to a different cancellation execution' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  SELECT request.* INTO v_approval FROM public.approval_requests AS request WHERE request.organization_id = p_organization_id AND request.resource_type = 'booking' AND request.resource_id = p_booking_id AND request.proposed_action = 'booking.cancel' AND request.status = 'approved' ORDER BY request.created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'approved cancellation is required' USING ERRCODE = '42501'; END IF;
  IF v_approval.requester_membership_id = v_actor THEN RAISE EXCEPTION 'requester cannot execute their own cancellation' USING ERRCODE = '42501'; END IF;
  v_now := clock_timestamp();
  -- An expired approval means there is no valid approval to execute: report it
  -- as invalid state (22023) rather than as a permission denial so callers map
  -- it to their invalid path.
  IF v_approval.expires_at IS NULL OR v_approval.expires_at <= v_now THEN RAISE EXCEPTION 'cancellation approval is expired' USING ERRCODE = '22023'; END IF;
  v_snapshot := jsonb_build_object('booking_id', p_booking_id, 'booking_version', v_booking.version, 'reason', v_approval.proposal_snapshot->>'reason');
  IF v_approval.proposal_snapshot <> v_snapshot OR v_approval.snapshot_hash <> encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex') THEN RAISE EXCEPTION 'cancellation snapshot is invalid' USING ERRCODE = '22023'; END IF;
  UPDATE public.bookings SET status = 'cancelled', idempotency_key = NULL, version = version + 1 WHERE organization_id = p_organization_id AND id = p_booking_id;
  UPDATE public.approval_requests SET status = 'executed', executed_at = v_now, updated_at = v_now WHERE organization_id = p_organization_id AND id = v_approval.id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta) VALUES (p_organization_id, 'user', v_actor, 'booking.cancelled', 'booking', p_booking_id, 'success', p_request_id, 'approved', jsonb_build_object('approval_request_id', v_approval.id, 'reason', v_approval.proposal_snapshot->>'reason'));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'booking.cancelled', 1, 'booking-cancelled:' || p_booking_id::text, jsonb_build_object('booking_id', p_booking_id, 'approval_request_id', v_approval.id));
  RETURN true;
END;
$$;

-- Execution boundary is unchanged: browser callers reach these commands only
-- through the authenticated role; the grants below restate the existing
-- posture so this migration is safe to apply on its own.
REVOKE ALL ON FUNCTION public.cancel_booking_draft(uuid, uuid, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.request_booking_cancellation(uuid, uuid, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.execute_booking_cancellation(uuid, uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_booking_draft(uuid, uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_booking_cancellation(uuid, uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.execute_booking_cancellation(uuid, uuid, text, uuid) TO authenticated;
