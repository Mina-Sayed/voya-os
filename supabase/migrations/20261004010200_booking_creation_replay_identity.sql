-- R05: bind commercial creation replays to immutable original command facts.
-- Recover historical identities only from one complete, attributable creation
-- event; current booking rows may already reflect approved amendments. Old
-- lifecycle commands that erased a key did not record that key in audit, so
-- those lost historical bindings cannot safely be reconstructed here.
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS creation_payload_hash text;
ALTER TABLE public.bookings DROP CONSTRAINT IF EXISTS bookings_creation_payload_hash_check;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_creation_payload_hash_check
  CHECK (creation_payload_hash IS NULL OR creation_payload_hash ~ '^[a-f0-9]{64}$');

WITH original_creation AS (
  SELECT organization_id, resource_id, (array_agg(after_delta))[1] AS facts
  FROM public.audit_events
  WHERE action = 'booking.commercial_draft_created'
    AND resource_type = 'booking' AND outcome = 'success'
  GROUP BY organization_id, resource_id
  HAVING count(*) = 1
), verified AS (
  SELECT organization_id, resource_id,
    jsonb_build_object('property_id', facts->'property_id', 'client_id', facts->'client_id',
      'check_in', facts->'check_in', 'check_out', facts->'check_out',
      'agreed_total_amount_minor', facts->'agreed_total_amount_minor', 'currency', facts->'currency') AS payload
  FROM original_creation
  WHERE jsonb_typeof(facts->'property_id') = 'string'
    AND jsonb_typeof(facts->'client_id') = 'string'
    AND (facts->>'property_id') ~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
    AND (facts->>'client_id') ~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
    AND jsonb_typeof(facts->'check_in') = 'string'
    AND jsonb_typeof(facts->'check_out') = 'string'
    AND (facts->>'check_in') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    AND (facts->>'check_out') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    AND jsonb_typeof(facts->'agreed_total_amount_minor') = 'number'
    AND (facts->>'agreed_total_amount_minor') ~ '^[0-9]{1,19}$'
    AND jsonb_typeof(facts->'currency') = 'string'
    AND (facts->>'currency') ~ '^[A-Z]{3}$'
)
UPDATE public.bookings AS booking
SET creation_payload_hash = encode(extensions.digest(verified.payload::text, 'sha256'), 'hex')
FROM verified
WHERE booking.organization_id = verified.organization_id AND booking.id = verified.resource_id
  AND booking.idempotency_key IS NOT NULL AND booking.creation_payload_hash IS NULL;

-- Prevent lifecycle edits from replacing an established command identity.
CREATE OR REPLACE FUNCTION public.preserve_booking_creation_identity_v1()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF OLD.creation_payload_hash IS NOT NULL
    AND NEW.creation_payload_hash IS DISTINCT FROM OLD.creation_payload_hash THEN
    RAISE EXCEPTION 'booking creation identity is immutable' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.preserve_booking_creation_identity_v1() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS bookings_preserve_creation_identity ON public.bookings;
CREATE TRIGGER bookings_preserve_creation_identity BEFORE UPDATE ON public.bookings
FOR EACH ROW EXECUTE FUNCTION public.preserve_booking_creation_identity_v1();

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
  v_payload_hash text;
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
  v_payload_hash := encode(extensions.digest(jsonb_build_object(
    'property_id', p_property_id, 'client_id', p_client_id,
    'check_in', p_check_in, 'check_out', p_check_out,
    'agreed_total_amount_minor', v_amount, 'currency', p_currency
  )::text, 'sha256'), 'hex');
  IF FOUND THEN
    IF v_existing.creation_payload_hash = v_payload_hash THEN
      RETURN v_existing.id;
    END IF;
    -- NULL means historical original facts could not be established. Fail
    -- closed rather than treating the current, possibly amended row as original.
    RAISE EXCEPTION 'booking creation idempotency payload conflicts or is unverifiable' USING ERRCODE = '23505';
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
    created_by_membership_id, idempotency_key, creation_payload_hash
  ) VALUES (
    p_organization_id, p_property_id, p_client_id, 'draft', p_check_in, p_check_out,
    v_amount, p_currency, 'complete', v_actor, btrim(p_idempotency_key), v_payload_hash
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

-- R04: forward redefinition also repairs databases that already applied the
-- older migration before its cancelled-draft branch was edited.
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

-- Preserve original creation keys on both authorized cancellation paths.
CREATE OR REPLACE FUNCTION public.cancel_booking_draft_without_workspace_aal2(
  p_organization_id uuid, p_booking_id uuid, p_reason text, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid; v_booking public.bookings%ROWTYPE;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'draft cancellation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000 OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'draft cancellation input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'draft' THEN RAISE EXCEPTION 'only a draft booking can be cancelled directly' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.booking_v1_command_idempotency (organization_id, command_name, idempotency_key, booking_id) VALUES (p_organization_id, 'booking.cancel.draft', btrim(p_idempotency_key), p_booking_id) ON CONFLICT DO NOTHING;
  UPDATE public.bookings SET status = 'cancelled', version = version + 1 WHERE organization_id = p_organization_id AND id = p_booking_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta) VALUES (p_organization_id, 'user', v_actor, 'booking.draft_cancelled', 'booking', p_booking_id, 'success', p_request_id, 'user_requested', jsonb_build_object('reason', btrim(p_reason)));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.execute_booking_cancellation_without_workspace_aal2(
  p_organization_id uuid, p_booking_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid; v_booking public.bookings%ROWTYPE; v_approval public.approval_requests%ROWTYPE; v_snapshot jsonb; v_now timestamptz;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'booking cancellation execution is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'cancellation execution idempotency key is invalid' USING ERRCODE = '22023'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'confirmed' THEN RAISE EXCEPTION 'booking is not cancellable' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.booking_v1_command_idempotency (organization_id, command_name, idempotency_key, booking_id) VALUES (p_organization_id, 'booking.cancel.execute', btrim(p_idempotency_key), p_booking_id) ON CONFLICT DO NOTHING;
  SELECT request.* INTO v_approval FROM public.approval_requests AS request WHERE request.organization_id = p_organization_id AND request.resource_type = 'booking' AND request.resource_id = p_booking_id AND request.proposed_action = 'booking.cancel' AND request.status = 'approved' ORDER BY request.created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'approved cancellation is required' USING ERRCODE = '42501'; END IF;
  IF v_approval.requester_membership_id = v_actor THEN RAISE EXCEPTION 'requester cannot execute their own cancellation' USING ERRCODE = '42501'; END IF;
  v_now := clock_timestamp();
  IF v_approval.expires_at IS NULL OR v_approval.expires_at <= v_now THEN RAISE EXCEPTION 'cancellation approval is expired' USING ERRCODE = '42501'; END IF;
  v_snapshot := jsonb_build_object('booking_id', p_booking_id, 'booking_version', v_booking.version, 'reason', v_approval.proposal_snapshot->>'reason');
  IF v_approval.proposal_snapshot <> v_snapshot OR v_approval.snapshot_hash <> encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex') THEN RAISE EXCEPTION 'cancellation snapshot is invalid' USING ERRCODE = '22023'; END IF;
  UPDATE public.bookings SET status = 'cancelled', version = version + 1 WHERE organization_id = p_organization_id AND id = p_booking_id;
  UPDATE public.approval_requests SET status = 'executed', executed_at = v_now, updated_at = v_now WHERE organization_id = p_organization_id AND id = v_approval.id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta) VALUES (p_organization_id, 'user', v_actor, 'booking.cancelled', 'booking', p_booking_id, 'success', p_request_id, 'approved', jsonb_build_object('approval_request_id', v_approval.id, 'reason', v_approval.proposal_snapshot->>'reason'));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'booking.cancelled', 1, 'booking-cancelled:' || p_booking_id::text, jsonb_build_object('booking_id', p_booking_id, 'approval_request_id', v_approval.id));
  RETURN true;
END;
$$;

-- Keep existing AAL2 wrappers for cancellation; private implementations
-- remain inaccessible to browser roles. Public create/confirm gate AAL2 inline.
REVOKE ALL ON FUNCTION public.create_commercial_booking_draft(uuid,uuid,uuid,date,date,text,text,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.confirm_commercial_booking(uuid,uuid,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_commercial_booking_draft(uuid,uuid,uuid,date,date,text,text,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_commercial_booking(uuid,uuid,text,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.cancel_booking_draft_without_workspace_aal2(uuid,uuid,text,text,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.execute_booking_cancellation_without_workspace_aal2(uuid,uuid,text,uuid) FROM PUBLIC, anon, authenticated;

-- The legacy confirmation RPC also accepts complete commercial bookings.
-- Keep an established commercial creation key while retaining its own command
-- binding. Only affirmative tenant-qualified legacy creation evidence may
-- retain its existing key-clearing behavior; unknown commercial identities
-- remain fail-closed and their keys cannot become reusable.
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
  SET status = 'confirmed',
    idempotency_key = CASE
      WHEN creation_payload_hash IS NULL
        AND EXISTS (
          SELECT 1 FROM public.audit_events AS creation_event
          WHERE creation_event.organization_id = p_organization_id
            AND creation_event.resource_id = p_booking_id
            AND creation_event.resource_type = 'booking'
            AND creation_event.action = 'booking.draft_created'
            AND creation_event.outcome = 'success'
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.audit_events AS commercial_creation_event
          WHERE commercial_creation_event.organization_id = p_organization_id
            AND commercial_creation_event.resource_id = p_booking_id
            AND commercial_creation_event.resource_type = 'booking'
            AND commercial_creation_event.action = 'booking.commercial_draft_created'
            AND commercial_creation_event.outcome = 'success'
        ) THEN NULL
      ELSE idempotency_key
    END,
    version = version + 1
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

REVOKE ALL ON FUNCTION public.confirm_booking(uuid,uuid,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_booking(uuid,uuid,text,uuid) TO authenticated;
