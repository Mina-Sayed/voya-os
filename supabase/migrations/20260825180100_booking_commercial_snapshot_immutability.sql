-- Voya OS: exact commercial completion idempotency and snapshot immutability.
-- Payload hashes make retry semantics exact for commands whose arguments are not
-- otherwise reconstructable from the booking row. Existing historical rows remain
-- nullable so forward deployment does not invent hashes for commands already run.
ALTER TABLE public.booking_v1_command_idempotency
  ADD COLUMN IF NOT EXISTS payload_hash text;

-- Legacy commercial completion may only fill an incomplete historical snapshot.
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
  v_amount bigint;
  v_org_currency text;
  v_existing_booking_id uuid;
  v_existing_payload_hash text;
  v_payload_hash text;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'commercial completion is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_amount_minor IS NULL OR p_amount_minor !~ '^[0-9]{1,19}$'
    OR p_currency IS NULL OR p_currency !~ '^[A-Z]{3}$'
    OR p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'commercial completion input is invalid' USING ERRCODE = '22023';
  END IF;

  BEGIN
    v_amount := p_amount_minor::bigint;
  EXCEPTION WHEN numeric_value_out_of_range THEN
    RAISE EXCEPTION 'commercial amount is out of range' USING ERRCODE = '22003';
  END;
  IF v_amount < 0 THEN
    RAISE EXCEPTION 'commercial amount is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT organization.default_currency INTO v_org_currency
  FROM public.organizations AS organization
  WHERE organization.id = p_organization_id AND organization.status = 'active';
  IF v_org_currency IS NULL OR p_currency <> v_org_currency THEN
    RAISE EXCEPTION 'booking currency must match organization currency' USING ERRCODE = '22023';
  END IF;

  v_payload_hash := encode(
    extensions.digest(
      jsonb_build_object(
        'booking_id', p_booking_id,
        'amount_minor', v_amount,
        'currency', p_currency,
        'reason', btrim(p_reason)
      )::text,
      'sha256'
    ),
    'hex'
  );

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503';
  END IF;

  SELECT booking_id, payload_hash
  INTO v_existing_booking_id, v_existing_payload_hash
  FROM public.booking_v1_command_idempotency
  WHERE organization_id = p_organization_id
    AND command_name = 'booking.commercial.complete'
    AND idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing_booking_id <> p_booking_id
      OR (v_existing_payload_hash IS NOT NULL AND v_existing_payload_hash <> v_payload_hash)
      OR (v_existing_payload_hash IS NULL
        AND (v_booking.agreed_total_amount_minor IS DISTINCT FROM v_amount
          OR v_booking.currency IS DISTINCT FROM p_currency)) THEN
      RAISE EXCEPTION 'commercial completion idempotency key payload mismatch' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  IF v_booking.commercial_completion_status <> 'needs_completion'
    OR v_booking.agreed_total_amount_minor IS NOT NULL
    OR v_booking.currency IS NOT NULL THEN
    RAISE EXCEPTION 'commercial snapshot is already complete' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.booking_v1_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id, payload_hash
  ) VALUES (
    p_organization_id, 'booking.commercial.complete', btrim(p_idempotency_key),
    p_booking_id, v_payload_hash
  );

  UPDATE public.bookings
  SET agreed_total_amount_minor = v_amount,
      currency = p_currency,
      commercial_completion_status = 'complete',
      version = version + 1
  WHERE organization_id = p_organization_id AND id = p_booking_id;

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
