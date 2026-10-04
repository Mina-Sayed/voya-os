-- R06-R08: keep booking command idempotency bound to the original command
-- facts across lifecycle transitions, with database serialization per key.
ALTER TABLE public.booking_v1_command_idempotency
  DROP CONSTRAINT IF EXISTS booking_v1_command_idempotency_command_name_check;
ALTER TABLE public.booking_v1_command_idempotency
  ADD CONSTRAINT booking_v1_command_idempotency_command_name_check
  CHECK (command_name IN (
    'booking.confirm.v1', 'booking.amend.request', 'booking.amend.execute',
    'booking.cancel.request', 'booking.cancel.execute', 'booking.cancel.draft',
    'booking.commercial.complete'
  ));

ALTER TABLE public.booking_v1_command_idempotency
  ADD COLUMN IF NOT EXISTS payload_hash text;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint
    WHERE conrelid = 'public.booking_v1_command_idempotency'::regclass
      AND conname = 'booking_v1_command_idempotency_payload_hash_check'
  ) THEN
    ALTER TABLE public.booking_v1_command_idempotency
      ADD CONSTRAINT booking_v1_command_idempotency_payload_hash_check
      CHECK (payload_hash IS NULL OR payload_hash ~ '^[a-f0-9]{64}$');
  END IF;
END;
$$;

-- Older confirm rows only recorded the target booking. That is the full input
-- payload of confirm_commercial_booking, so it can be backfilled exactly.
UPDATE public.booking_v1_command_idempotency
SET payload_hash = encode(
  extensions.digest(jsonb_build_object('booking_id', booking_id)::text, 'sha256'),
  'hex'
)
WHERE command_name = 'booking.confirm.v1'
  AND payload_hash IS NULL;

CREATE OR REPLACE FUNCTION public.create_commercial_booking_draft(
  p_organization_id uuid,
  p_property_id uuid,
  p_client_id uuid,
  p_check_in date,
  p_check_out date,
  p_amount_minor text,
  p_currency text,
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
  v_existing public.bookings%ROWTYPE;
  v_id uuid;
  v_amount bigint;
  v_org_currency text;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'commercial booking creation is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_check_in IS NULL OR p_check_out IS NULL OR p_check_in >= p_check_out
    OR p_amount_minor IS NULL OR p_amount_minor !~ '^[0-9]{1,19}$'
    OR p_currency IS NULL OR p_currency !~ '^[A-Z]{3}$'
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'commercial booking input is invalid' USING ERRCODE = '22023';
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
  IF v_org_currency IS NULL THEN
    RAISE EXCEPTION 'organization is invalid' USING ERRCODE = '23503';
  END IF;
  IF p_currency <> v_org_currency THEN
    RAISE EXCEPTION 'booking currency must match organization currency' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text || ':booking.commercial.draft:' || btrim(p_idempotency_key), 0)
  );
  SELECT booking.* INTO v_existing
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.idempotency_key = btrim(p_idempotency_key)
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.property_id = p_property_id
      AND v_existing.client_id = p_client_id
      AND v_existing.check_in = p_check_in
      AND v_existing.check_out = p_check_out
      AND v_existing.agreed_total_amount_minor = v_amount
      AND v_existing.currency = p_currency THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'booking idempotency key belongs to a different booking' USING ERRCODE = '23505';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.properties
    WHERE organization_id = p_organization_id AND id = p_property_id AND status = 'active'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.clients
    WHERE organization_id = p_organization_id AND id = p_client_id
  ) THEN
    RAISE EXCEPTION 'booking property or client is invalid' USING ERRCODE = '23503';
  END IF;

  INSERT INTO public.bookings (
    organization_id, property_id, client_id, status, check_in, check_out,
    agreed_total_amount_minor, currency, commercial_completion_status,
    created_by_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, p_property_id, p_client_id, 'draft', p_check_in, p_check_out,
    v_amount, p_currency, 'complete', v_actor, btrim(p_idempotency_key)
  ) RETURNING id INTO v_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.commercial_draft_created', 'booking',
    v_id, 'success', p_request_id,
    jsonb_build_object('property_id', p_property_id, 'client_id', p_client_id,
      'check_in', p_check_in, 'check_out', p_check_out,
      'agreed_total_amount_minor', v_amount, 'currency', p_currency)
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'booking.commercial_draft.created', 1,
    'booking-commercial-draft:' || v_id::text, jsonb_build_object('booking_id', v_id));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_commercial_booking(
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
  v_existing public.booking_v1_command_idempotency%ROWTYPE;
  v_snapshot jsonb;
  v_payload_hash text;
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
    RAISE EXCEPTION 'commercial booking confirmation is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_booking_id IS NULL OR p_idempotency_key IS NULL
    OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'booking confirmation idempotency key is invalid' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text || ':booking.confirm.v1:' || btrim(p_idempotency_key), 0)
  );
  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503'; END IF;

  v_payload_hash := encode(
    extensions.digest(jsonb_build_object('booking_id', p_booking_id)::text, 'sha256'),
    'hex'
  );
  SELECT command_record.* INTO v_existing
  FROM public.booking_v1_command_idempotency AS command_record
  WHERE command_record.organization_id = p_organization_id
    AND command_record.command_name = 'booking.confirm.v1'
    AND command_record.idempotency_key = btrim(p_idempotency_key)
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.booking_id <> p_booking_id
      OR v_existing.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'booking confirmation key belongs to a different payload' USING ERRCODE = '23505';
    END IF;
    IF v_booking.status IN ('confirmed', 'checked_in', 'checked_out', 'cancelled', 'completed') THEN
      RETURN true;
    END IF;
  END IF;
  -- A fresh confirm command is not a replay when the booking is cancelled.
  -- Only confirmed/completed bookings can establish a new successful key here.
  IF v_booking.status IN ('confirmed', 'checked_in', 'checked_out', 'completed') THEN
    INSERT INTO public.booking_v1_command_idempotency (
      organization_id, command_name, idempotency_key, booking_id, payload_hash
    ) VALUES (
      p_organization_id, 'booking.confirm.v1', btrim(p_idempotency_key), p_booking_id, v_payload_hash
    ) ON CONFLICT DO NOTHING;
    SELECT command_record.* INTO v_existing
    FROM public.booking_v1_command_idempotency AS command_record
    WHERE command_record.organization_id = p_organization_id
      AND command_record.command_name = 'booking.confirm.v1'
      AND command_record.idempotency_key = btrim(p_idempotency_key)
    FOR UPDATE;
    IF NOT FOUND OR v_existing.booking_id <> p_booking_id
      OR v_existing.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'booking confirmation key belongs to a different payload' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;
  IF v_booking.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'booking is not awaiting commercial confirmation' USING ERRCODE = '22023';
  END IF;

  SELECT request.* INTO v_approval
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.resource_type = 'booking'
    AND request.resource_id = p_booking_id
    AND request.proposed_action = 'booking.confirm'
    AND request.status = 'approved'
  ORDER BY request.created_at DESC
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking approval is required' USING ERRCODE = '42501'; END IF;
  IF v_approval.requester_membership_id = v_actor THEN
    RAISE EXCEPTION 'requester cannot confirm their own booking' USING ERRCODE = '42501';
  END IF;
  v_now := clock_timestamp();
  IF v_approval.expires_at IS NULL OR v_approval.expires_at <= v_now THEN
    RAISE EXCEPTION 'booking approval is expired' USING ERRCODE = '42501';
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
  IF v_approval.proposal_snapshot <> v_snapshot
    OR v_approval.snapshot_hash <> encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'booking no longer matches its approved snapshot' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.properties
    WHERE organization_id = p_organization_id AND id = v_booking.property_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'booking property is not active' USING ERRCODE = '23503';
  END IF;

  INSERT INTO public.booking_v1_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id, payload_hash
  ) VALUES (
    p_organization_id, 'booking.confirm.v1', btrim(p_idempotency_key), p_booking_id, v_payload_hash
  ) ON CONFLICT DO NOTHING;
  SELECT command_record.* INTO v_existing
  FROM public.booking_v1_command_idempotency AS command_record
  WHERE command_record.organization_id = p_organization_id
    AND command_record.command_name = 'booking.confirm.v1'
    AND command_record.idempotency_key = btrim(p_idempotency_key)
  FOR UPDATE;
  IF NOT FOUND OR v_existing.booking_id <> p_booking_id
    OR v_existing.payload_hash IS DISTINCT FROM v_payload_hash THEN
    RAISE EXCEPTION 'booking confirmation key belongs to a different payload' USING ERRCODE = '23505';
  END IF;

  UPDATE public.bookings
  SET status = 'confirmed', version = version + 1
  WHERE organization_id = p_organization_id AND id = p_booking_id;
  UPDATE public.approval_requests
  SET status = 'executed', executed_at = v_now, updated_at = v_now
  WHERE organization_id = p_organization_id AND id = v_approval.id;
  INSERT INTO public.notifications (organization_id, recipient_membership_id, category, title, body, resource_type, resource_id, dedupe_key)
  SELECT p_organization_id, membership.id, 'operational', 'تم تأكيد الحجز', 'تم تأكيد الحجز التجاري بعد الاعتماد.', 'booking', p_booking_id,
    'booking-confirmed:' || p_booking_id::text || ':' || membership.id::text
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.status = 'active' AND membership.id <> v_actor;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.commercial_confirmed', 'booking',
    p_booking_id, 'success', p_request_id,
    jsonb_build_object('approval_request_id', v_approval.id,
      'amount_minor', v_booking.agreed_total_amount_minor, 'currency', v_booking.currency)
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'booking.commercial_confirmed', 1,
    'booking-commercial-confirmed:' || p_booking_id::text,
    jsonb_build_object('booking_id', p_booking_id));
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
  v_normalized_notes text;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
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
  v_normalized_notes := NULLIF(btrim(p_notes), '');

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text || ':booking.stay.event:' || btrim(p_idempotency_key), 0)
  );
  SELECT event.* INTO v_existing
  FROM public.booking_stay_events AS event
  WHERE event.organization_id = p_organization_id
    AND event.idempotency_key = btrim(p_idempotency_key)
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.booking_id = p_booking_id
      AND v_existing.event_type = p_event_type
      AND v_existing.notes IS NOT DISTINCT FROM v_normalized_notes THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'stay event key belongs to a different payload' USING ERRCODE = '23505';
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
    p_organization_id, p_booking_id, p_event_type, v_normalized_notes, v_actor, btrim(p_idempotency_key)
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
    jsonb_build_object('event_id', v_id, 'notes', v_normalized_notes)
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'booking.' || p_event_type, 1,
    'booking-commercial-stay:' || v_id::text,
    jsonb_build_object('booking_id', p_booking_id, 'event_id', v_id));
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_commercial_booking_draft(uuid,uuid,uuid,date,date,text,text,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.confirm_commercial_booking(uuid,uuid,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_commercial_booking_stay_event(uuid,uuid,text,text,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_commercial_booking_draft(uuid,uuid,uuid,date,date,text,text,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_commercial_booking(uuid,uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_commercial_booking_stay_event(uuid,uuid,text,text,text,uuid) TO authenticated;
