-- Booking integrity follow-up:
--
-- Keep historical incomplete operational rows readable, but make every new
-- booking write and stay-event write fail closed until the commercial snapshot
-- is complete. Legacy booking commands keep their public signatures while
-- gaining the workspace AAL2 boundary and stale-approval recovery.

CREATE OR REPLACE FUNCTION public.enforce_booking_commercial_confirmation_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.status IN ('confirmed', 'checked_in', 'checked_out', 'completed')
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
  BEFORE INSERT OR UPDATE ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_booking_commercial_confirmation_v1();

CREATE OR REPLACE FUNCTION public.enforce_booking_stay_event_commercial_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_complete boolean;
BEGIN
  SELECT (
    booking.commercial_completion_status = 'complete'
    AND booking.agreed_total_amount_minor IS NOT NULL
    AND booking.currency IS NOT NULL
  )
  INTO v_complete
  FROM public.bookings AS booking
  WHERE booking.organization_id = NEW.organization_id
    AND booking.id = NEW.booking_id
  FOR UPDATE;

  IF NOT COALESCE(v_complete, false) THEN
    RAISE EXCEPTION 'booking commercial completion is required before a stay event' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS booking_stay_events_require_commercial_snapshot
  ON public.booking_stay_events;
CREATE TRIGGER booking_stay_events_require_commercial_snapshot
  BEFORE INSERT ON public.booking_stay_events
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_booking_stay_event_commercial_v1();

ALTER TABLE public.booking_v1_command_idempotency
  ADD COLUMN IF NOT EXISTS payload_hash text;

-- Preserve the original commercial payload for completion keys created before
-- payload_hash existed. Rows that cannot be reconstructed are deliberately
-- left NULL and fail closed on retry below.
UPDATE public.booking_v1_command_idempotency AS idempotency
SET payload_hash = encode(
  extensions.digest(
    jsonb_build_object(
      'agreed_total_amount_minor', booking.agreed_total_amount_minor,
      'currency', booking.currency
    )::text,
    'sha256'
  ),
  'hex'
)
FROM public.bookings AS booking
WHERE idempotency.organization_id = booking.organization_id
  AND idempotency.booking_id = booking.id
  AND idempotency.command_name = 'booking.commercial.complete'
  AND idempotency.payload_hash IS NULL
  AND booking.agreed_total_amount_minor IS NOT NULL
  AND booking.currency IS NOT NULL;

CREATE OR REPLACE FUNCTION public.complete_booking_commercial_snapshot(
  p_organization_id uuid,
  p_booking_id uuid,
  p_amount_minor text,
  p_currency text,
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
  v_existing public.booking_v1_command_idempotency%ROWTYPE;
  v_amount bigint;
  v_org_currency text;
  v_payload_hash text;
BEGIN
  PERFORM public.require_workspace_aal2_v1();

  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'commercial completion is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_amount_minor IS NULL
    OR p_amount_minor !~ '^[0-9]{1,19}$'
    OR p_currency IS NULL
    OR p_currency !~ '^[A-Z]{3}$'
    OR p_reason IS NULL
    OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000
    OR p_idempotency_key IS NULL
    OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'commercial completion input is invalid' USING ERRCODE = '22023';
  END IF;

  BEGIN
    v_amount := p_amount_minor::bigint;
  EXCEPTION WHEN numeric_value_out_of_range THEN
    RAISE EXCEPTION 'commercial amount is out of range' USING ERRCODE = '22003';
  END;
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

  v_payload_hash := encode(
    extensions.digest(
      jsonb_build_object(
        'agreed_total_amount_minor', v_amount,
        'currency', p_currency
      )::text,
      'sha256'
    ),
    'hex'
  );

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503';
  END IF;
  IF v_booking.status <> 'draft' THEN
    RAISE EXCEPTION 'commercial snapshot can only be completed while booking is draft' USING ERRCODE = '22023';
  END IF;

  SELECT idempotency.* INTO v_existing
  FROM public.booking_v1_command_idempotency AS idempotency
  WHERE idempotency.organization_id = p_organization_id
    AND idempotency.command_name = 'booking.commercial.complete'
    AND idempotency.idempotency_key = btrim(p_idempotency_key)
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.booking_id <> p_booking_id THEN
      RAISE EXCEPTION 'commercial completion idempotency key belongs to a different booking' USING ERRCODE = '23505';
    END IF;
    IF v_existing.payload_hash IS NULL THEN
      RAISE EXCEPTION 'commercial completion idempotency record has no stable payload hash' USING ERRCODE = '55000';
    END IF;
    IF v_existing.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'commercial completion idempotency key was reused with a different payload' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  INSERT INTO public.booking_v1_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id, payload_hash
  ) VALUES (
    p_organization_id, 'booking.commercial.complete', btrim(p_idempotency_key), p_booking_id, v_payload_hash
  );

  UPDATE public.bookings
  SET agreed_total_amount_minor = v_amount,
      currency = p_currency,
      commercial_completion_status = 'complete',
      version = version + 1
  WHERE organization_id = p_organization_id
    AND id = p_booking_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, reason_code, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.commercial_completed', 'booking',
    p_booking_id, 'success', p_request_id, 'legacy_completion',
    jsonb_build_object(
      'agreed_total_amount_minor', v_booking.agreed_total_amount_minor,
      'currency', v_booking.currency
    ),
    jsonb_build_object(
      'agreed_total_amount_minor', v_amount,
      'currency', p_currency,
      'reason', btrim(p_reason)
    )
  );
  RETURN true;
END;
$$;

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
  v_snapshot_hash text;
  v_now timestamptz;
BEGIN
  PERFORM public.require_workspace_aal2_v1();

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
  IF v_booking.commercial_completion_status IS DISTINCT FROM 'complete'
    OR v_booking.agreed_total_amount_minor IS NULL
    OR v_booking.currency IS NULL THEN
    RAISE EXCEPTION 'booking commercial completion is required' USING ERRCODE = '22023';
  END IF;
  IF (
    SELECT count(*)
    FROM public.organization_memberships
    WHERE organization_id = p_organization_id
      AND status = 'active'
      AND role IN ('owner', 'manager')
  ) < 2 THEN
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
      IF v_existing.proposal_snapshot = v_snapshot
        AND v_existing.snapshot_hash = v_snapshot_hash THEN
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

      UPDATE public.approval_requests
      SET status = 'cancelled', updated_at = v_now
      WHERE organization_id = p_organization_id
        AND resource_type = 'booking'
        AND resource_id = p_booking_id
        AND proposed_action = 'booking.confirm'
        AND status IN ('pending', 'approved');
    END IF;
  ELSIF v_booking.status <> 'draft' THEN
    RAISE EXCEPTION 'booking cannot request approval in its current state' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.properties AS property_record
    WHERE property_record.organization_id = p_organization_id
      AND property_record.id = v_booking.property_id
      AND property_record.status = 'active'
  ) THEN
    RAISE EXCEPTION 'booking property is not active' USING ERRCODE = '23503';
  END IF;

  v_now := clock_timestamp();
  INSERT INTO public.approval_requests (
    organization_id, resource_type, resource_id, proposed_action,
    proposal_snapshot, snapshot_hash, requester_membership_id, expires_at
  ) VALUES (
    p_organization_id, 'booking', p_booking_id, 'booking.confirm',
    v_snapshot, v_snapshot_hash, v_actor, v_now + interval '24 hours'
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
  PERFORM public.require_workspace_aal2_v1();

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
  IF v_booking.commercial_completion_status IS DISTINCT FROM 'complete'
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
    SELECT 1
    FROM public.properties AS property_record
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
REVOKE ALL ON FUNCTION public.enforce_booking_stay_event_commercial_v1() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.complete_booking_commercial_snapshot(uuid, uuid, text, text, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.request_booking_approval(uuid, uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.confirm_booking(uuid, uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_booking_commercial_snapshot(uuid, uuid, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_booking_approval(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_booking(uuid, uuid, text, uuid) TO authenticated;

COMMENT ON FUNCTION public.complete_booking_commercial_snapshot(uuid, uuid, text, text, text, text, uuid)
  IS 'Completes a booking commercial snapshot only while the booking is draft; use the amendment flow for later states.';
COMMENT ON FUNCTION public.request_booking_approval(uuid, uuid, text, uuid)
  IS 'Compatibility booking approval command; requires workspace AAL2 and refreshes stale snapshots.';
COMMENT ON FUNCTION public.confirm_booking(uuid, uuid, text, uuid)
  IS 'Compatibility booking confirmation command; requires workspace AAL2 and complete commercial terms.';
