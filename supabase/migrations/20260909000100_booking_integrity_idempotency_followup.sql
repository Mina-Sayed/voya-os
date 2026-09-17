-- Booking integrity follow-up.
--
-- Keep the original booking-integrity migration immutable. This migration
-- closes the upgrade-boundary ambiguity, adds stable approval-command results,
-- and replaces the command implementations with the corrected idempotency and
-- serialization behavior.

-- The preceding migration could only derive a legacy completion hash from the
-- mutable booking row and did not include the reason. No immutable evidence
-- distinguishes those values from the original request, so fail closed for
-- every pre-follow-up completion binding instead of guessing.
UPDATE public.booking_v1_command_idempotency
SET payload_hash = NULL
WHERE command_name = 'booking.commercial.complete'
  AND payload_hash IS NOT NULL;

ALTER TABLE public.booking_command_idempotency
  ADD COLUMN IF NOT EXISTS result_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.booking_command_idempotency'::regclass
      AND conname = 'booking_command_idempotency_result_tenant_fk'
  ) THEN
    ALTER TABLE public.booking_command_idempotency
      ADD CONSTRAINT booking_command_idempotency_result_tenant_fk
      FOREIGN KEY (organization_id, result_id)
      REFERENCES public.approval_requests(organization_id, id)
      ON DELETE RESTRICT;
  END IF;
END;
$$;

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
        'currency', p_currency,
        'reason', btrim(p_reason)
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

  IF v_booking.status <> 'draft' THEN
    RAISE EXCEPTION 'commercial snapshot can only be completed while booking is draft' USING ERRCODE = '22023';
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

  -- Serialize the checker-count decision with membership role, suspension,
  -- and removal commands that use the same organization lock.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text, 1)
  );

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
  IF v_binding.result_id IS NOT NULL THEN
    RETURN v_binding.result_id;
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
        UPDATE public.booking_command_idempotency
        SET result_id = v_existing.id
        WHERE organization_id = p_organization_id
          AND command_name = 'booking.approval.request'
          AND idempotency_key = btrim(p_idempotency_key)
          AND result_id IS NULL;
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

  UPDATE public.booking_command_idempotency
  SET result_id = v_approval
  WHERE organization_id = p_organization_id
    AND command_name = 'booking.approval.request'
    AND idempotency_key = btrim(p_idempotency_key)
    AND result_id IS NULL;

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

COMMENT ON FUNCTION public.complete_booking_commercial_snapshot(uuid, uuid, text, text, text, text, uuid)
  IS 'Creates a booking commercial snapshot only while the booking is draft; exact idempotent retries remain valid after later workflow transitions, while new changes use the amendment flow.';
COMMENT ON FUNCTION public.request_booking_approval(uuid, uuid, text, uuid)
  IS 'Compatibility booking approval command; requires workspace AAL2, refreshes stale snapshots, and binds each idempotency key to its resulting approval request.';
