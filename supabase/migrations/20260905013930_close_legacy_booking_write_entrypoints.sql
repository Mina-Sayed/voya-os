-- R-02: keep legacy booking signatures for compatibility, but make them use
-- the commercial completion and snapshot contract before a booking can move
-- into an operationally confirmed state.

CREATE OR REPLACE FUNCTION public.enforce_booking_commercial_confirmation_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.status IN ('confirmed', 'checked_in')
    AND OLD.status NOT IN ('confirmed', 'checked_in')
    AND (
      NEW.commercial_completion_status <> 'complete'
      OR NEW.agreed_total_amount_minor IS NULL
      OR NEW.currency IS NULL
    ) THEN
    RAISE EXCEPTION 'booking commercial completion is required' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS bookings_require_commercial_confirmation
  ON public.bookings;
CREATE TRIGGER bookings_require_commercial_confirmation
  BEFORE UPDATE OF status, agreed_total_amount_minor, currency,
    commercial_completion_status ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_booking_commercial_confirmation_v1();

CREATE OR REPLACE FUNCTION public.request_booking_approval(
  p_organization_id uuid,
  p_booking_id uuid,
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
  v_binding public.booking_command_idempotency%ROWTYPE;
  v_existing public.approval_requests%ROWTYPE;
  v_approval uuid;
  v_snapshot jsonb;
  v_now timestamptz;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking approval request is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL
    OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'booking approval idempotency key is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503';
  END IF;
  IF v_booking.commercial_completion_status <> 'complete'
    OR v_booking.agreed_total_amount_minor IS NULL
    OR v_booking.currency IS NULL THEN
    RAISE EXCEPTION 'booking commercial completion is required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.booking_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id
  ) VALUES (
    p_organization_id, 'booking.approval.request', btrim(p_idempotency_key), p_booking_id
  )
  ON CONFLICT DO NOTHING;

  SELECT binding.* INTO v_binding
  FROM public.booking_command_idempotency AS binding
  WHERE binding.organization_id = p_organization_id
    AND binding.command_name = 'booking.approval.request'
    AND binding.idempotency_key = btrim(p_idempotency_key)
  FOR UPDATE;
  IF NOT FOUND OR v_binding.booking_id <> p_booking_id THEN
    RAISE EXCEPTION 'booking approval idempotency key belongs to a different command' USING ERRCODE = '23505';
  END IF;

  IF v_booking.status = 'pending_approval' THEN
    PERFORM request.id
    FROM public.approval_requests AS request
    WHERE request.organization_id = p_organization_id
      AND request.resource_type = 'booking'
      AND request.resource_id = p_booking_id
      AND request.proposed_action = 'booking.confirm'
      AND request.status IN ('pending', 'approved')
    FOR UPDATE;

    v_now := clock_timestamp();
    UPDATE public.approval_requests
    SET status = 'expired', updated_at = v_now
    WHERE organization_id = p_organization_id
      AND resource_type = 'booking'
      AND resource_id = p_booking_id
      AND proposed_action = 'booking.confirm'
      AND status IN ('pending', 'approved')
      AND (expires_at IS NULL OR expires_at <= v_now);

    SELECT request.* INTO v_existing
    FROM public.approval_requests AS request
    WHERE request.organization_id = p_organization_id
      AND request.resource_type = 'booking'
      AND request.resource_id = p_booking_id
      AND request.proposed_action = 'booking.confirm'
      AND request.status IN ('pending', 'approved')
      AND request.expires_at > v_now
    ORDER BY (request.status = 'approved') DESC,
      request.created_at DESC, request.id DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      UPDATE public.approval_requests
      SET status = 'cancelled', updated_at = v_now
      WHERE organization_id = p_organization_id
        AND resource_type = 'booking'
        AND resource_id = p_booking_id
        AND proposed_action = 'booking.confirm'
        AND status IN ('pending', 'approved')
        AND id <> v_existing.id;
      RETURN v_existing.id;
    END IF;
  ELSIF v_booking.status <> 'draft' THEN
    RAISE EXCEPTION 'booking cannot request approval in its current state' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.properties AS property_record
    WHERE property_record.organization_id = p_organization_id
      AND property_record.id = v_booking.property_id
      AND property_record.status = 'active'
  ) THEN
    RAISE EXCEPTION 'booking property is not active' USING ERRCODE = '23503';
  END IF;

  v_snapshot := jsonb_build_object(
    'booking_id', v_booking.id,
    'booking_version', v_booking.version,
    'property_id', v_booking.property_id,
    'client_id', v_booking.client_id,
    'check_in', v_booking.check_in,
    'check_out', v_booking.check_out,
    'agreed_total_amount_minor', v_booking.agreed_total_amount_minor,
    'currency', v_booking.currency,
    'status', 'draft'
  );
  v_now := clock_timestamp();
  INSERT INTO public.approval_requests (
    organization_id, resource_type, resource_id, proposed_action,
    proposal_snapshot, snapshot_hash, requester_membership_id, expires_at
  ) VALUES (
    p_organization_id, 'booking', p_booking_id, 'booking.confirm',
    v_snapshot, encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'),
    v_actor, v_now + interval '24 hours'
  ) RETURNING id INTO v_approval;

  UPDATE public.bookings
  SET status = 'pending_approval'
  WHERE organization_id = p_organization_id
    AND id = p_booking_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.approval_requested',
    'booking', p_booking_id, 'success', p_request_id,
    jsonb_build_object('approval_request_id', v_approval)
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'booking.approval.requested', 1,
    'booking-approval:' || v_approval::text,
    jsonb_build_object('approval_request_id', v_approval, 'booking_id', p_booking_id)
  );
  RETURN v_approval;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_booking(
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
  v_binding public.booking_command_idempotency%ROWTYPE;
  v_approval public.approval_requests%ROWTYPE;
  v_snapshot jsonb;
  v_snapshot_hash text;
  v_now timestamptz;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking confirmation is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL
    OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'booking confirmation idempotency key is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503';
  END IF;

  INSERT INTO public.booking_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id
  ) VALUES (
    p_organization_id, 'booking.confirm', btrim(p_idempotency_key), p_booking_id
  )
  ON CONFLICT DO NOTHING;

  SELECT binding.* INTO v_binding
  FROM public.booking_command_idempotency AS binding
  WHERE binding.organization_id = p_organization_id
    AND binding.command_name = 'booking.confirm'
    AND binding.idempotency_key = btrim(p_idempotency_key)
  FOR UPDATE;
  IF NOT FOUND OR v_binding.booking_id <> p_booking_id THEN
    RAISE EXCEPTION 'booking confirmation idempotency key belongs to a different command' USING ERRCODE = '23505';
  END IF;

  IF v_booking.status IN ('confirmed', 'completed') THEN
    RETURN true;
  END IF;
  IF v_booking.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'booking is not awaiting confirmation' USING ERRCODE = '22023';
  END IF;
  IF v_booking.commercial_completion_status <> 'complete'
    OR v_booking.agreed_total_amount_minor IS NULL
    OR v_booking.currency IS NULL THEN
    RAISE EXCEPTION 'booking commercial completion is required' USING ERRCODE = '22023';
  END IF;

  SELECT request.* INTO v_approval
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.resource_type = 'booking'
    AND request.resource_id = p_booking_id
    AND request.proposed_action = 'booking.confirm'
    AND request.status = 'approved'
  ORDER BY request.created_at DESC, request.id DESC
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking approval is required' USING ERRCODE = '42501';
  END IF;

  v_now := clock_timestamp();
  IF v_approval.expires_at IS NULL OR v_approval.expires_at <= v_now THEN
    RAISE EXCEPTION 'booking approval is expired' USING ERRCODE = '42501';
  END IF;
  IF v_approval.requester_membership_id = v_actor THEN
    RAISE EXCEPTION 'requester cannot confirm their own booking' USING ERRCODE = '42501';
  END IF;

  v_snapshot := jsonb_build_object(
    'booking_id', v_booking.id,
    'booking_version', v_booking.version,
    'property_id', v_booking.property_id,
    'client_id', v_booking.client_id,
    'check_in', v_booking.check_in,
    'check_out', v_booking.check_out,
    'agreed_total_amount_minor', v_booking.agreed_total_amount_minor,
    'currency', v_booking.currency,
    'status', 'draft'
  );
  v_snapshot_hash := encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex');
  IF v_approval.proposal_snapshot <> v_snapshot
    OR v_approval.snapshot_hash <> v_snapshot_hash THEN
    RAISE EXCEPTION 'booking no longer matches its approved snapshot' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.properties AS property_record
    WHERE property_record.organization_id = p_organization_id
      AND property_record.id = v_booking.property_id
      AND property_record.status = 'active'
  ) THEN
    RAISE EXCEPTION 'booking property is not active' USING ERRCODE = '23503';
  END IF;

  UPDATE public.bookings
  SET status = 'confirmed', idempotency_key = NULL, version = version + 1
  WHERE organization_id = p_organization_id
    AND id = p_booking_id;
  UPDATE public.approval_requests
  SET status = 'executed', executed_at = v_now, updated_at = v_now
  WHERE organization_id = p_organization_id
    AND id = v_approval.id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.confirmed',
    'booking', p_booking_id, 'success', p_request_id,
    jsonb_build_object(
      'approval_request_id', v_approval.id,
      'agreed_total_amount_minor', v_booking.agreed_total_amount_minor,
      'currency', v_booking.currency
    )
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'booking.confirmed', 1,
    'booking-confirmed:' || p_booking_id::text,
    jsonb_build_object('booking_id', p_booking_id)
  );
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_booking_commercial_confirmation_v1() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.request_booking_approval(uuid, uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.confirm_booking(uuid, uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_booking_approval(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_booking(uuid, uuid, text, uuid) TO authenticated;

COMMENT ON FUNCTION public.request_booking_approval(uuid, uuid, text, uuid)
  IS 'Compatibility booking approval command; commercial completion and snapshot are mandatory.';
COMMENT ON FUNCTION public.confirm_booking(uuid, uuid, text, uuid)
  IS 'Compatibility booking confirmation command; delegates commercial invariants and is owner/manager-only.';
