-- R-02 follow-up (PR31 review gaps):
--
-- 1) The commercial-confirmation trigger fired only on UPDATE, so a direct
--    INSERT of a confirmed/checked_in/completed row bypassed it. It now fires
--    on INSERT as well, and the NULL-unsafe comparison is replaced with
--    IS DISTINCT FROM.
-- 2) Stay-event transitions out of confirmed/checked_in (check-in, checkout,
--    direct completion) skipped the guard because OLD was already operational.
--    Any transition INTO confirmed/checked_in/completed now requires complete
--    commercial fields, so legacy stay events cannot complete a booking that
--    never satisfied the commercial contract. Historical rows stay readable;
--    moving them operationally requires completing the commercial snapshot.
-- 3) Legacy request_booking_approval gains the same 2-checker operational
--    readiness gate as request_commercial_booking_approval: with fewer than
--    two active owner/manager memberships the request is rejected loudly
--    (APPROVAL_NOT_OPERATIONALLY_READY) instead of stranding the booking in
--    pending_approval that nobody else can confirm.

CREATE OR REPLACE FUNCTION public.enforce_booking_commercial_confirmation_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.status IN ('confirmed', 'checked_in', 'completed')
    AND (
      TG_OP = 'INSERT'
      OR OLD.status IS DISTINCT FROM NEW.status
    )
    AND (
      NEW.commercial_completion_status IS DISTINCT FROM 'complete'
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
  BEFORE INSERT OR UPDATE OF status, agreed_total_amount_minor, currency,
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
  IF (SELECT count(*) FROM public.organization_memberships WHERE organization_id = p_organization_id AND status = 'active' AND role IN ('owner', 'manager')) < 2 THEN
    RAISE EXCEPTION 'APPROVAL_NOT_OPERATIONALLY_READY' USING ERRCODE = '42501';
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
      AND resource_id = p_booking_id
      AND proposed_action = 'booking.confirm'
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
