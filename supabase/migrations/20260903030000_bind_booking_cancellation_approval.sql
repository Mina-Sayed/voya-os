-- Voya OS: bind cancellation execution to the exact approval projected to the
-- checker UI, and complete the trusted executable-change projection for
-- cancellation approvals.
--
-- Cancellation execution keeps the existing tenant, role, maker-checker,
-- expiry, snapshot, occupancy, audit, and outbox boundaries. The only command
-- contract change is that callers must provide the approval_request_id they
-- received from list_executable_booking_changes_v1.

-- The previous four-argument function selected the newest approved
-- cancellation for the booking. Remove that callable surface before exposing
-- the approval-bound five-argument command.
DROP FUNCTION IF EXISTS public.execute_booking_cancellation(uuid, uuid, text, uuid);

CREATE OR REPLACE FUNCTION public.list_executable_booking_changes_v1(
  p_organization_id uuid
)
RETURNS TABLE (
  booking_id uuid,
  approval_request_id uuid,
  proposed_action text,
  expires_at timestamptz,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking executable approval read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT DISTINCT ON (request.resource_id, request.proposed_action)
    request.resource_id,
    request.id,
    request.proposed_action,
    request.expires_at,
    request.created_at
  FROM public.approval_requests AS request
  JOIN public.bookings AS booking
    ON booking.organization_id = request.organization_id
   AND booking.id = request.resource_id
  WHERE request.organization_id = p_organization_id
    AND request.resource_type = 'booking'
    AND request.proposed_action IN ('booking.confirm', 'booking.amend', 'booking.cancel')
    AND request.status = 'approved'
    AND request.expires_at IS NOT NULL
    AND request.expires_at > timezone('utc', now())
    AND request.requester_membership_id <> v_actor
    AND request.snapshot_hash = encode(extensions.digest(request.proposal_snapshot::text, 'sha256'), 'hex')
    AND (
      (
        request.proposed_action = 'booking.confirm'
        AND booking.status = 'pending_approval'
        AND EXISTS (
          SELECT 1
          FROM public.properties AS confirmation_property
          WHERE confirmation_property.organization_id = booking.organization_id
            AND confirmation_property.id = booking.property_id
            AND confirmation_property.status = 'active'
        )
        AND request.proposal_snapshot = jsonb_build_object(
          'booking_id', booking.id,
          'booking_version', booking.version,
          'property_id', booking.property_id,
          'client_id', booking.client_id,
          'check_in', booking.check_in,
          'check_out', booking.check_out,
          'agreed_total_amount_minor', booking.agreed_total_amount_minor,
          'currency', booking.currency,
          'status', 'draft'
        )
      )
      OR (
        request.proposed_action = 'booking.amend'
        AND booking.status = 'confirmed'
        AND request.proposal_snapshot->>'booking_version' ~ '^[0-9]+$'
        AND request.proposal_snapshot->>'property_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND request.proposal_snapshot->>'client_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND (request.proposal_snapshot->>'booking_version')::integer = booking.version
        AND EXISTS (
          SELECT 1
          FROM public.properties AS amendment_property
          WHERE amendment_property.organization_id = booking.organization_id
            AND amendment_property.id = (request.proposal_snapshot->>'property_id')::uuid
            AND amendment_property.status = 'active'
        )
        AND EXISTS (
          SELECT 1
          FROM public.clients AS amendment_client
          WHERE amendment_client.organization_id = booking.organization_id
            AND amendment_client.id = (request.proposal_snapshot->>'client_id')::uuid
            AND amendment_client.archived_at IS NULL
        )
      )
      OR (
        request.proposed_action = 'booking.cancel'
        AND booking.status = 'confirmed'
        AND request.proposal_snapshot->>'booking_version' ~ '^[0-9]+$'
        AND request.proposal_snapshot->>'booking_version' = booking.version::text
        AND char_length(btrim(coalesce(request.proposal_snapshot->>'reason', ''))) BETWEEN 1 AND 1000
        AND request.proposal_snapshot = jsonb_build_object(
          'booking_id', booking.id,
          'booking_version', booking.version,
          'reason', request.proposal_snapshot->>'reason'
        )
      )
    )
  ORDER BY request.resource_id, request.proposed_action, request.created_at DESC, request.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_executable_booking_changes_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_executable_booking_changes_v1(uuid) TO authenticated;

ALTER TABLE public.booking_v1_command_idempotency
  ADD COLUMN IF NOT EXISTS payload_hash text;

-- Preserve replayability for draft cancellations written by the previous
-- migration when their audit evidence is available. Rows without evidence
-- remain fail-closed because their payload cannot be proven.
UPDATE public.booking_v1_command_idempotency AS idempotency
SET payload_hash = encode(
  extensions.digest(
    jsonb_build_object('reason', audit.after_delta->>'reason')::text,
    'sha256'
  ),
  'hex'
)
FROM public.audit_events AS audit
WHERE idempotency.organization_id = audit.organization_id
  AND idempotency.booking_id = audit.resource_id
  AND idempotency.command_name = 'booking.cancel.draft'
  AND idempotency.payload_hash IS NULL
  AND audit.action = 'booking.draft_cancelled'
  AND audit.resource_type = 'booking'
  AND audit.after_delta ? 'reason';

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
  v_payload_hash text := encode(
    extensions.digest(
      jsonb_build_object('reason', btrim(p_reason))::text,
      'sha256'
    ),
    'hex'
  );
  v_existing_booking uuid;
  v_existing_payload_hash text;
  v_inserted_count integer;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'draft cancellation is not permitted' USING ERRCODE = '42501';
  END IF;

  IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000
    OR p_idempotency_key IS NULL OR char_length(v_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'draft cancellation input is invalid' USING ERRCODE = '22023';
  END IF;

  -- Replay a committed cancellation before touching the booking row. The
  -- reason hash is part of the durable command binding, so key reuse with a
  -- different reason fails closed with 23505.
  SELECT idempotency.booking_id, idempotency.payload_hash
    INTO v_existing_booking, v_existing_payload_hash
  FROM public.booking_v1_command_idempotency AS idempotency
  WHERE idempotency.organization_id = p_organization_id
    AND idempotency.command_name = 'booking.cancel.draft'
    AND idempotency.idempotency_key = v_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_booking IS DISTINCT FROM p_booking_id
      OR v_existing_payload_hash IS NULL
      OR v_existing_payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'idempotency key belongs to a different draft cancellation' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  INSERT INTO public.booking_v1_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id, payload_hash
  ) VALUES (
    p_organization_id, 'booking.cancel.draft', v_key, p_booking_id, v_payload_hash
  )
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  IF v_inserted_count = 0 THEN
    SELECT idempotency.booking_id, idempotency.payload_hash
      INTO v_existing_booking, v_existing_payload_hash
    FROM public.booking_v1_command_idempotency AS idempotency
    WHERE idempotency.organization_id = p_organization_id
      AND idempotency.command_name = 'booking.cancel.draft'
      AND idempotency.idempotency_key = v_key
    FOR UPDATE;

    IF NOT FOUND
      OR v_existing_booking IS DISTINCT FROM p_booking_id
      OR v_existing_payload_hash IS NULL
      OR v_existing_payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'idempotency key belongs to a different draft cancellation' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'draft' THEN
    RAISE EXCEPTION 'only a draft booking can be cancelled directly' USING ERRCODE = '22023';
  END IF;

  UPDATE public.bookings
  SET status = 'cancelled', idempotency_key = NULL, version = version + 1
  WHERE organization_id = p_organization_id
    AND id = p_booking_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, reason_code, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.draft_cancelled', 'booking',
    p_booking_id, 'success', p_request_id, 'user_requested',
    jsonb_build_object('reason', btrim(p_reason))
  );
  RETURN true;
END;
$$;

CREATE FUNCTION public.execute_booking_cancellation(
  p_organization_id uuid,
  p_booking_id uuid,
  p_approval_request_id uuid,
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
  v_existing_approval uuid;
  v_inserted_count integer;
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

  IF p_booking_id IS NULL
    OR p_approval_request_id IS NULL
    OR p_idempotency_key IS NULL
    OR char_length(v_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'cancellation execution input is invalid' USING ERRCODE = '22023';
  END IF;

  -- Bind retries to both the booking and the exact approved request, matching
  -- the amendment execution command's idempotency contract.
  SELECT idempotency.booking_id, idempotency.result_id
    INTO v_existing_booking, v_existing_approval
  FROM public.booking_v1_command_idempotency AS idempotency
  WHERE idempotency.organization_id = p_organization_id
    AND idempotency.command_name = 'booking.cancel.execute'
    AND idempotency.idempotency_key = v_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_booking IS DISTINCT FROM p_booking_id
      OR v_existing_approval IS NULL
      OR v_existing_approval IS DISTINCT FROM p_approval_request_id THEN
      RAISE EXCEPTION 'idempotency key belongs to a different cancellation execution' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  INSERT INTO public.booking_v1_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id, result_id
  ) VALUES (
    p_organization_id, 'booking.cancel.execute', v_key, p_booking_id, p_approval_request_id
  )
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  IF v_inserted_count = 0 THEN
    SELECT idempotency.booking_id, idempotency.result_id
      INTO v_existing_booking, v_existing_approval
    FROM public.booking_v1_command_idempotency AS idempotency
    WHERE idempotency.organization_id = p_organization_id
      AND idempotency.command_name = 'booking.cancel.execute'
      AND idempotency.idempotency_key = v_key
    FOR UPDATE;

    IF NOT FOUND
      OR v_existing_booking IS DISTINCT FROM p_booking_id
      OR v_existing_approval IS NULL
      OR v_existing_approval IS DISTINCT FROM p_approval_request_id THEN
      RAISE EXCEPTION 'idempotency key belongs to a different cancellation execution' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'confirmed' THEN
    RAISE EXCEPTION 'booking is not cancellable' USING ERRCODE = '22023';
  END IF;

  SELECT request.* INTO v_approval
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_approval_request_id
    AND request.resource_type = 'booking'
    AND request.resource_id = p_booking_id
    AND request.proposed_action = 'booking.cancel'
    AND request.status = 'approved'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'approved cancellation is required' USING ERRCODE = '42501';
  END IF;
  IF v_approval.requester_membership_id = v_actor THEN
    RAISE EXCEPTION 'requester cannot execute their own cancellation' USING ERRCODE = '42501';
  END IF;

  v_now := clock_timestamp();
  IF v_approval.expires_at IS NULL OR v_approval.expires_at <= v_now THEN
    RAISE EXCEPTION 'cancellation approval is expired' USING ERRCODE = '22023';
  END IF;

  v_snapshot := jsonb_build_object(
    'booking_id', v_booking.id,
    'booking_version', v_booking.version,
    'reason', v_approval.proposal_snapshot->>'reason'
  );
  IF v_approval.proposal_snapshot <> v_snapshot
    OR v_approval.snapshot_hash <> encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'cancellation snapshot is invalid' USING ERRCODE = '22023';
  END IF;

  UPDATE public.bookings
  SET status = 'cancelled', idempotency_key = NULL, version = version + 1
  WHERE organization_id = p_organization_id
    AND id = p_booking_id;
  UPDATE public.approval_requests
  SET status = 'executed', executed_at = v_now, updated_at = v_now
  WHERE organization_id = p_organization_id
    AND id = v_approval.id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, reason_code, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.cancelled', 'booking',
    p_booking_id, 'success', p_request_id, 'approved',
    jsonb_build_object('approval_request_id', v_approval.id, 'reason', v_approval.proposal_snapshot->>'reason')
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

REVOKE ALL ON FUNCTION public.cancel_booking_draft(uuid, uuid, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.request_booking_cancellation(uuid, uuid, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.execute_booking_cancellation(uuid, uuid, uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_booking_draft(uuid, uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_booking_cancellation(uuid, uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.execute_booking_cancellation(uuid, uuid, uuid, text, uuid) TO authenticated;
