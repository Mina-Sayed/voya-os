-- Voya OS V1: commercial booking snapshots layered over the existing
-- operational booking foundation. Historical rows remain intact and receive
-- NEEDS_COMPLETION instead of an invented amount.

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS agreed_total_amount_minor bigint,
  ADD COLUMN IF NOT EXISTS currency text,
  ADD COLUMN IF NOT EXISTS commercial_completion_status text NOT NULL DEFAULT 'needs_completion',
  ADD COLUMN IF NOT EXISTS created_by_membership_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.bookings'::regclass
      AND conname = 'bookings_agreed_total_amount_minor_check'
  ) THEN
    ALTER TABLE public.bookings
      ADD CONSTRAINT bookings_agreed_total_amount_minor_check
      CHECK (agreed_total_amount_minor IS NULL OR agreed_total_amount_minor >= 0);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.bookings'::regclass
      AND conname = 'bookings_currency_check'
  ) THEN
    ALTER TABLE public.bookings
      ADD CONSTRAINT bookings_currency_check
      CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.bookings'::regclass
      AND conname = 'bookings_commercial_completion_status_check'
  ) THEN
    ALTER TABLE public.bookings
      ADD CONSTRAINT bookings_commercial_completion_status_check
      CHECK (commercial_completion_status IN ('complete', 'needs_completion'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.bookings'::regclass
      AND conname = 'bookings_created_by_membership_tenant_fk'
  ) THEN
    ALTER TABLE public.bookings
      ADD CONSTRAINT bookings_created_by_membership_tenant_fk
      FOREIGN KEY (organization_id, created_by_membership_id)
      REFERENCES public.organization_memberships(organization_id, id)
      ON DELETE RESTRICT;
  END IF;
END;
$$;

UPDATE public.bookings
SET commercial_completion_status = CASE
  WHEN agreed_total_amount_minor IS NOT NULL AND currency IS NOT NULL THEN 'complete'
  ELSE 'needs_completion'
END;

ALTER TABLE public.bookings DROP CONSTRAINT IF EXISTS bookings_status_check;
ALTER TABLE public.bookings
  ADD CONSTRAINT bookings_status_check
  CHECK (status IN ('draft', 'pending_approval', 'confirmed', 'checked_in', 'checked_out', 'cancelled', 'completed'));

ALTER TABLE public.bookings DROP CONSTRAINT IF EXISTS bookings_no_confirmed_overlap;
ALTER TABLE public.bookings
  ADD CONSTRAINT bookings_no_confirmed_overlap
  EXCLUDE USING gist (
    organization_id WITH =,
    property_id WITH =,
    daterange(check_in, check_out, '[)') WITH &&
  ) WHERE (status IN ('confirmed', 'checked_in'));

CREATE OR REPLACE FUNCTION public.sync_booking_occupancy()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $$
BEGIN
  DELETE FROM public.property_occupancies
  WHERE booking_id = NEW.id;

  IF NEW.status IN ('confirmed', 'checked_in') THEN
    INSERT INTO public.property_occupancies (
      organization_id, property_id, booking_id, start_date, end_date
    ) VALUES (
      NEW.organization_id, NEW.property_id, NEW.id, NEW.check_in, NEW.check_out
    );
  END IF;

  RETURN NEW;
END;
$$;

CREATE TABLE public.booking_v1_command_idempotency (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  command_name text NOT NULL CHECK (command_name IN (
    'booking.confirm.v1', 'booking.amend.request', 'booking.amend.execute',
    'booking.cancel.request', 'booking.cancel.execute', 'booking.cancel.draft',
    'booking.commercial.complete'
  )),
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  booking_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT booking_v1_command_idempotency_pkey
    PRIMARY KEY (organization_id, command_name, idempotency_key),
  CONSTRAINT booking_v1_command_booking_tenant_fk
    FOREIGN KEY (organization_id, booking_id)
    REFERENCES public.bookings(organization_id, id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX booking_v1_confirm_once_idx
  ON public.booking_v1_command_idempotency (organization_id, booking_id)
  WHERE command_name = 'booking.confirm.v1';
CREATE INDEX booking_v1_command_booking_idx
  ON public.booking_v1_command_idempotency (organization_id, booking_id, command_name);
ALTER TABLE public.booking_v1_command_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.booking_v1_command_idempotency FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.booking_v1_command_idempotency FROM PUBLIC, anon, authenticated;

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
  IF NOT EXISTS (
    SELECT 1 FROM public.properties
    WHERE organization_id = p_organization_id AND id = p_property_id AND status = 'active'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.clients
    WHERE organization_id = p_organization_id AND id = p_client_id
  ) THEN
    RAISE EXCEPTION 'booking property or client is invalid' USING ERRCODE = '23503';
  END IF;

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
      AND v_existing.currency = p_currency
      AND v_existing.status = 'draft' THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'booking idempotency key belongs to a different booking' USING ERRCODE = '23505';
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
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'commercial completion is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_amount_minor IS NULL OR p_amount_minor !~ '^[0-9]{1,19}$'
    OR p_currency IS NULL OR p_currency !~ '^[A-Z]{3}$'
    OR p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'commercial completion input is invalid' USING ERRCODE = '22023';
  END IF;
  v_amount := p_amount_minor::bigint;
  SELECT organization.default_currency INTO v_org_currency FROM public.organizations AS organization
  WHERE organization.id = p_organization_id AND organization.status = 'active';
  IF p_currency <> v_org_currency THEN RAISE EXCEPTION 'booking currency must match organization currency' USING ERRCODE = '22023'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503'; END IF;
  INSERT INTO public.booking_v1_command_idempotency (organization_id, command_name, idempotency_key, booking_id)
  VALUES (p_organization_id, 'booking.commercial.complete', btrim(p_idempotency_key), p_booking_id)
  ON CONFLICT DO NOTHING;
  IF v_booking.agreed_total_amount_minor IS NOT NULL AND v_booking.currency IS NOT NULL
    AND v_booking.agreed_total_amount_minor = v_amount AND v_booking.currency = p_currency THEN
    RETURN true;
  END IF;
  UPDATE public.bookings SET agreed_total_amount_minor = v_amount, currency = p_currency,
    commercial_completion_status = 'complete', version = version + 1
  WHERE organization_id = p_organization_id AND id = p_booking_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, before_delta, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'booking.commercial_completed', 'booking', p_booking_id, 'success', p_request_id, 'legacy_completion',
    jsonb_build_object('agreed_total_amount_minor', v_booking.agreed_total_amount_minor, 'currency', v_booking.currency),
    jsonb_build_object('agreed_total_amount_minor', v_amount, 'currency', p_currency, 'reason', btrim(p_reason)));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_commercial_booking_work_queue(p_organization_id uuid)
RETURNS TABLE (
  id uuid, property_code text, property_name text, client_name text, status text,
  check_in date, check_out date, agreed_total_amount_minor text, currency text,
  commercial_completion_status text, version integer, has_check_in boolean,
  has_check_out boolean, created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_role text;
BEGIN
  SELECT membership.role INTO v_role FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'accountant', 'viewer') THEN
    RAISE EXCEPTION 'commercial booking read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT booking.id, property_record.code, property_record.name, client_record.display_name,
    booking.status, booking.check_in, booking.check_out,
    booking.agreed_total_amount_minor::text, booking.currency,
    booking.commercial_completion_status, booking.version,
    EXISTS (SELECT 1 FROM public.booking_stay_events AS stay_event WHERE stay_event.organization_id = booking.organization_id AND stay_event.booking_id = booking.id AND stay_event.event_type = 'check_in'),
    EXISTS (SELECT 1 FROM public.booking_stay_events AS stay_event WHERE stay_event.organization_id = booking.organization_id AND stay_event.booking_id = booking.id AND stay_event.event_type = 'check_out'),
    booking.created_at
  FROM public.bookings AS booking
  JOIN public.properties AS property_record ON property_record.organization_id = booking.organization_id AND property_record.id = booking.property_id
  LEFT JOIN public.clients AS client_record ON client_record.organization_id = booking.organization_id AND client_record.id = booking.client_id
  WHERE booking.organization_id = p_organization_id
  ORDER BY (booking.status IN ('completed', 'checked_out', 'cancelled')), booking.check_in, booking.created_at DESC, booking.id DESC;
END;
$$;

-- Extend the existing booking approval decision boundary to cover the V1
-- amendment and cancellation approval records. The legacy confirm path keeps
-- the same RPC contract, while change requests remain independently approved
-- and executable by a different owner or manager.
CREATE OR REPLACE FUNCTION public.decide_booking_approval(
  p_organization_id uuid,
  p_approval_request_id uuid,
  p_decision text,
  p_reason text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_booking_id uuid;
  v_request public.approval_requests%ROWTYPE;
  v_booking public.bookings%ROWTYPE;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking approval decision is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_decision IS NULL
    OR p_decision NOT IN ('approved', 'rejected')
    OR p_reason IS NULL
    OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'approval decision is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT request.resource_id INTO v_booking_id
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_approval_request_id
    AND request.resource_type = 'booking'
    AND request.proposed_action IN ('booking.confirm', 'booking.amend', 'booking.cancel');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'approval request is no longer actionable' USING ERRCODE = '22023';
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.id = v_booking_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking is no longer awaiting approval' USING ERRCODE = '22023';
  END IF;

  SELECT request.* INTO v_request
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_approval_request_id
    AND request.resource_type = 'booking'
    AND request.proposed_action IN ('booking.confirm', 'booking.amend', 'booking.cancel')
  FOR UPDATE;
  IF NOT FOUND
    OR v_request.resource_id <> v_booking.id
    OR v_request.status <> 'pending'
    OR (v_request.expires_at IS NOT NULL AND v_request.expires_at <= timezone('utc', now())) THEN
    RAISE EXCEPTION 'approval request is no longer actionable' USING ERRCODE = '22023';
  END IF;
  IF v_request.requester_membership_id = v_actor THEN
    RAISE EXCEPTION 'requester cannot approve their own booking change' USING ERRCODE = '42501';
  END IF;
  IF (v_request.proposed_action = 'booking.confirm' AND v_booking.status <> 'pending_approval')
    OR (v_request.proposed_action IN ('booking.amend', 'booking.cancel') AND v_booking.status <> 'confirmed') THEN
    RAISE EXCEPTION 'booking is no longer in the required approval state' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.approval_decisions (
    organization_id, approval_request_id, approver_membership_id, decision, reason
  ) VALUES (
    p_organization_id, p_approval_request_id, v_actor, p_decision, btrim(p_reason)
  );
  UPDATE public.approval_requests
  SET status = p_decision, updated_at = timezone('utc', now())
  WHERE organization_id = p_organization_id AND id = p_approval_request_id;
  IF p_decision = 'rejected' AND v_request.proposed_action = 'booking.confirm' THEN
    UPDATE public.bookings
    SET status = 'draft'
    WHERE organization_id = p_organization_id AND id = v_request.resource_id;
  END IF;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.approval.' || p_decision, 'booking',
    v_request.resource_id, 'success', p_request_id,
    jsonb_build_object('approval_request_id', p_approval_request_id, 'proposed_action', v_request.proposed_action, 'reason', btrim(p_reason))
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id,
    'booking.approval.' || p_decision,
    1,
    'booking-approval-decision:' || p_approval_request_id::text || ':' || p_decision,
    jsonb_build_object('approval_request_id', p_approval_request_id, 'booking_id', v_request.resource_id, 'proposed_action', v_request.proposed_action)
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.request_commercial_booking_approval(
  p_organization_id uuid, p_booking_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid; v_booking public.bookings%ROWTYPE; v_existing public.approval_requests%ROWTYPE;
  v_approval uuid; v_snapshot jsonb; v_now timestamptz;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'commercial booking approval request is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'booking approval idempotency key is invalid' USING ERRCODE = '22023'; END IF;
  IF (SELECT count(*) FROM public.organization_memberships WHERE organization_id = p_organization_id AND status = 'active' AND role IN ('owner', 'manager')) < 2 THEN
    RAISE EXCEPTION 'APPROVAL_NOT_OPERATIONALLY_READY' USING ERRCODE = '42501';
  END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503'; END IF;
  IF v_booking.status = 'pending_approval' THEN
    SELECT request.* INTO v_existing FROM public.approval_requests AS request
    WHERE request.organization_id = p_organization_id AND request.resource_type = 'booking' AND request.resource_id = p_booking_id
      AND request.proposed_action = 'booking.confirm' AND request.status = 'pending' AND request.expires_at > timezone('utc', now())
    ORDER BY request.created_at DESC LIMIT 1;
    IF FOUND THEN RETURN v_existing.id; END IF;
  ELSIF v_booking.status <> 'draft' THEN
    RAISE EXCEPTION 'booking cannot request commercial approval in its current state' USING ERRCODE = '22023';
  END IF;
  IF v_booking.commercial_completion_status <> 'complete' OR v_booking.agreed_total_amount_minor IS NULL OR v_booking.currency IS NULL THEN
    RAISE EXCEPTION 'booking commercial completion is required' USING ERRCODE = '22023';
  END IF;
  v_snapshot := jsonb_build_object('booking_id', v_booking.id, 'booking_version', v_booking.version,
    'property_id', v_booking.property_id, 'client_id', v_booking.client_id, 'check_in', v_booking.check_in,
    'check_out', v_booking.check_out, 'agreed_total_amount_minor', v_booking.agreed_total_amount_minor,
    'currency', v_booking.currency, 'status', 'draft');
  v_now := clock_timestamp();
  INSERT INTO public.approval_requests (organization_id, resource_type, resource_id, proposed_action, proposal_snapshot, snapshot_hash, requester_membership_id, expires_at)
  VALUES (p_organization_id, 'booking', p_booking_id, 'booking.confirm', v_snapshot, encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'), v_actor, v_now + interval '24 hours')
  RETURNING id INTO v_approval;
  UPDATE public.bookings SET status = 'pending_approval' WHERE organization_id = p_organization_id AND id = p_booking_id;
  INSERT INTO public.notifications (organization_id, recipient_membership_id, category, title, body, resource_type, resource_id, dedupe_key)
  SELECT p_organization_id, membership.id, 'approval', 'حجز يحتاج اعتمادًا', 'يوجد حجز تجاري جديد ينتظر مراجعة مستقلة.', 'booking', p_booking_id,
    'booking-approval:' || v_approval::text || ':' || membership.id::text
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.status = 'active' AND membership.role IN ('owner', 'manager') AND membership.id <> v_actor;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'booking.commercial_approval_requested', 'booking', p_booking_id, 'success', p_request_id, jsonb_build_object('approval_request_id', v_approval, 'snapshot_hash', encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex')));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'booking.commercial_approval.requested', 1, 'booking-commercial-approval:' || v_approval::text, jsonb_build_object('approval_request_id', v_approval, 'booking_id', p_booking_id));
  RETURN v_approval;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_commercial_booking(
  p_organization_id uuid, p_booking_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid; v_booking public.bookings%ROWTYPE; v_approval public.approval_requests%ROWTYPE;
  v_snapshot jsonb; v_now timestamptz;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'commercial booking confirmation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'booking confirmation idempotency key is invalid' USING ERRCODE = '22023'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503'; END IF;
  IF v_booking.status = 'confirmed' THEN RETURN true; END IF;
  IF v_booking.status <> 'pending_approval' THEN RAISE EXCEPTION 'booking is not awaiting commercial confirmation' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.booking_v1_command_idempotency (organization_id, command_name, idempotency_key, booking_id)
  VALUES (p_organization_id, 'booking.confirm.v1', btrim(p_idempotency_key), p_booking_id) ON CONFLICT DO NOTHING;
  SELECT request.* INTO v_approval FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id AND request.resource_type = 'booking' AND request.resource_id = p_booking_id
    AND request.proposed_action = 'booking.confirm' AND request.status = 'approved'
  ORDER BY request.created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking approval is required' USING ERRCODE = '42501'; END IF;
  IF v_approval.requester_membership_id = v_actor THEN RAISE EXCEPTION 'requester cannot confirm their own booking' USING ERRCODE = '42501'; END IF;
  v_now := clock_timestamp();
  IF v_approval.expires_at IS NULL OR v_approval.expires_at <= v_now THEN RAISE EXCEPTION 'booking approval is expired' USING ERRCODE = '42501'; END IF;
  v_snapshot := jsonb_build_object('booking_id', v_booking.id, 'booking_version', v_booking.version,
    'property_id', v_booking.property_id, 'client_id', v_booking.client_id, 'check_in', v_booking.check_in,
    'check_out', v_booking.check_out, 'agreed_total_amount_minor', v_booking.agreed_total_amount_minor,
    'currency', v_booking.currency, 'status', 'draft');
  IF v_approval.proposal_snapshot <> v_snapshot OR v_approval.snapshot_hash <> encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'booking no longer matches its approved snapshot' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.properties WHERE organization_id = p_organization_id AND id = v_booking.property_id AND status = 'active') THEN
    RAISE EXCEPTION 'booking property is not active' USING ERRCODE = '23503';
  END IF;
  UPDATE public.bookings SET status = 'confirmed', idempotency_key = NULL, version = version + 1
  WHERE organization_id = p_organization_id AND id = p_booking_id;
  UPDATE public.approval_requests SET status = 'executed', executed_at = v_now, updated_at = v_now WHERE organization_id = p_organization_id AND id = v_approval.id;
  INSERT INTO public.notifications (organization_id, recipient_membership_id, category, title, body, resource_type, resource_id, dedupe_key)
  SELECT p_organization_id, membership.id, 'operational', 'تم تأكيد الحجز', 'تم تأكيد الحجز التجاري بعد الاعتماد.', 'booking', p_booking_id,
    'booking-confirmed:' || p_booking_id::text || ':' || membership.id::text
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.status = 'active' AND membership.id <> v_actor;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'booking.commercial_confirmed', 'booking', p_booking_id, 'success', p_request_id, jsonb_build_object('approval_request_id', v_approval.id, 'amount_minor', v_booking.agreed_total_amount_minor, 'currency', v_booking.currency));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'booking.commercial_confirmed', 1, 'booking-commercial-confirmed:' || p_booking_id::text, jsonb_build_object('booking_id', p_booking_id));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.request_booking_amendment(
  p_organization_id uuid, p_booking_id uuid, p_property_id uuid, p_client_id uuid,
  p_check_in date, p_check_out date, p_amount_minor text, p_currency text,
  p_reason text, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid; v_booking public.bookings%ROWTYPE; v_approval uuid; v_snapshot jsonb; v_amount bigint; v_org_currency text;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'booking amendment request is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_check_in IS NULL OR p_check_out IS NULL OR p_check_in >= p_check_out OR p_amount_minor IS NULL OR p_amount_minor !~ '^[0-9]{1,19}$'
    OR p_currency IS NULL OR p_currency !~ '^[A-Z]{3}$' OR p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'booking amendment input is invalid' USING ERRCODE = '22023';
  END IF;
  v_amount := p_amount_minor::bigint;
  SELECT organization.default_currency INTO v_org_currency FROM public.organizations AS organization WHERE organization.id = p_organization_id AND organization.status = 'active';
  IF p_currency <> v_org_currency THEN RAISE EXCEPTION 'booking currency must match organization currency' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.properties WHERE organization_id = p_organization_id AND id = p_property_id AND status = 'active')
    OR NOT EXISTS (SELECT 1 FROM public.clients WHERE organization_id = p_organization_id AND id = p_client_id) THEN RAISE EXCEPTION 'amendment property or client is invalid' USING ERRCODE = '23503'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'confirmed' THEN RAISE EXCEPTION 'only a confirmed booking can be amended' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.booking_v1_command_idempotency (organization_id, command_name, idempotency_key, booking_id)
  VALUES (p_organization_id, 'booking.amend.request', btrim(p_idempotency_key), p_booking_id) ON CONFLICT DO NOTHING;
  v_snapshot := jsonb_build_object('booking_id', v_booking.id, 'booking_version', v_booking.version,
    'property_id', p_property_id, 'client_id', p_client_id, 'check_in', p_check_in, 'check_out', p_check_out,
    'agreed_total_amount_minor', v_amount, 'currency', p_currency, 'reason', btrim(p_reason));
  INSERT INTO public.approval_requests (organization_id, resource_type, resource_id, proposed_action, proposal_snapshot, snapshot_hash, requester_membership_id, expires_at)
  VALUES (p_organization_id, 'booking', p_booking_id, 'booking.amend', v_snapshot, encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'), v_actor, clock_timestamp() + interval '24 hours') RETURNING id INTO v_approval;
  INSERT INTO public.notifications (organization_id, recipient_membership_id, category, title, body, resource_type, resource_id, dedupe_key)
  SELECT p_organization_id, membership.id, 'approval', 'تعديل حجز يحتاج اعتمادًا', 'يوجد اقتراح تعديل حجز ينتظر مراجعة مستقلة.', 'booking', p_booking_id,
    'booking-amendment-approval:' || v_approval::text || ':' || membership.id::text
  FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.status = 'active' AND membership.role IN ('owner', 'manager') AND membership.id <> v_actor;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'booking.amendment_requested', 'booking', p_booking_id, 'success', p_request_id, jsonb_build_object('approval_request_id', v_approval, 'reason', btrim(p_reason)));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'booking.amendment.requested', 1, 'booking-amendment:' || v_approval::text, jsonb_build_object('approval_request_id', v_approval, 'booking_id', p_booking_id));
  RETURN v_approval;
END;
$$;

CREATE OR REPLACE FUNCTION public.execute_booking_amendment(
  p_organization_id uuid, p_booking_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid; v_booking public.bookings%ROWTYPE; v_approval public.approval_requests%ROWTYPE; v_snapshot jsonb; v_now timestamptz; v_new_property uuid; v_new_client uuid; v_new_amount bigint; v_new_currency text;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'booking amendment execution is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'amendment execution idempotency key is invalid' USING ERRCODE = '22023'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'confirmed' THEN RAISE EXCEPTION 'booking is not amendable' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.booking_v1_command_idempotency (organization_id, command_name, idempotency_key, booking_id) VALUES (p_organization_id, 'booking.amend.execute', btrim(p_idempotency_key), p_booking_id) ON CONFLICT DO NOTHING;
  SELECT request.* INTO v_approval FROM public.approval_requests AS request WHERE request.organization_id = p_organization_id AND request.resource_type = 'booking' AND request.resource_id = p_booking_id AND request.proposed_action = 'booking.amend' AND request.status = 'approved' ORDER BY request.created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'approved amendment is required' USING ERRCODE = '42501'; END IF;
  IF v_approval.requester_membership_id = v_actor THEN RAISE EXCEPTION 'requester cannot execute their own amendment' USING ERRCODE = '42501'; END IF;
  v_now := clock_timestamp();
  IF v_approval.expires_at IS NULL OR v_approval.expires_at <= v_now THEN RAISE EXCEPTION 'amendment approval is expired' USING ERRCODE = '42501'; END IF;
  v_new_property := (v_approval.proposal_snapshot->>'property_id')::uuid;
  v_new_client := (v_approval.proposal_snapshot->>'client_id')::uuid;
  v_new_amount := (v_approval.proposal_snapshot->>'agreed_total_amount_minor')::bigint;
  v_new_currency := v_approval.proposal_snapshot->>'currency';
  v_snapshot := jsonb_build_object('booking_id', v_booking.id, 'booking_version', v_booking.version, 'property_id', v_new_property, 'client_id', v_new_client, 'check_in', (v_approval.proposal_snapshot->>'check_in')::date, 'check_out', (v_approval.proposal_snapshot->>'check_out')::date, 'agreed_total_amount_minor', v_new_amount, 'currency', v_new_currency, 'reason', v_approval.proposal_snapshot->>'reason');
  IF v_approval.proposal_snapshot <> v_snapshot OR v_approval.snapshot_hash <> encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex') THEN RAISE EXCEPTION 'amendment snapshot is invalid' USING ERRCODE = '22023'; END IF;
  IF (v_approval.proposal_snapshot->>'booking_version')::integer <> v_booking.version THEN RAISE EXCEPTION 'booking version is stale' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.properties WHERE organization_id = p_organization_id AND id = v_new_property AND status = 'active') OR NOT EXISTS (SELECT 1 FROM public.clients WHERE organization_id = p_organization_id AND id = v_new_client) THEN RAISE EXCEPTION 'amendment property or client is invalid' USING ERRCODE = '23503'; END IF;
  UPDATE public.bookings SET property_id = v_new_property, client_id = v_new_client, check_in = (v_approval.proposal_snapshot->>'check_in')::date, check_out = (v_approval.proposal_snapshot->>'check_out')::date, agreed_total_amount_minor = v_new_amount, currency = v_new_currency, commercial_completion_status = 'complete', version = version + 1 WHERE organization_id = p_organization_id AND id = p_booking_id;
  UPDATE public.approval_requests SET status = 'executed', executed_at = v_now, updated_at = v_now WHERE organization_id = p_organization_id AND id = v_approval.id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'booking.amended', 'booking', p_booking_id, 'success', p_request_id, jsonb_build_object('approval_request_id', v_approval.id, 'booking_version', v_booking.version, 'reason', v_approval.proposal_snapshot->>'reason'));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'booking.amended', 1, 'booking-amended:' || p_booking_id::text || ':' || v_booking.version::text, jsonb_build_object('booking_id', p_booking_id, 'approval_request_id', v_approval.id));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_booking_draft(
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
  UPDATE public.bookings SET status = 'cancelled', idempotency_key = NULL, version = version + 1 WHERE organization_id = p_organization_id AND id = p_booking_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta) VALUES (p_organization_id, 'user', v_actor, 'booking.draft_cancelled', 'booking', p_booking_id, 'success', p_request_id, 'user_requested', jsonb_build_object('reason', btrim(p_reason)));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.request_booking_cancellation(
  p_organization_id uuid, p_booking_id uuid, p_reason text, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid; v_booking public.bookings%ROWTYPE; v_snapshot jsonb; v_approval uuid;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'booking cancellation request is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000 OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'booking cancellation input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'confirmed' THEN RAISE EXCEPTION 'only a confirmed booking can be cancelled through approval' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.booking_v1_command_idempotency (organization_id, command_name, idempotency_key, booking_id) VALUES (p_organization_id, 'booking.cancel.request', btrim(p_idempotency_key), p_booking_id) ON CONFLICT DO NOTHING;
  v_snapshot := jsonb_build_object('booking_id', p_booking_id, 'booking_version', v_booking.version, 'reason', btrim(p_reason));
  INSERT INTO public.approval_requests (organization_id, resource_type, resource_id, proposed_action, proposal_snapshot, snapshot_hash, requester_membership_id, expires_at) VALUES (p_organization_id, 'booking', p_booking_id, 'booking.cancel', v_snapshot, encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'), v_actor, clock_timestamp() + interval '24 hours') RETURNING id INTO v_approval;
  INSERT INTO public.notifications (organization_id, recipient_membership_id, category, title, body, resource_type, resource_id, dedupe_key)
  SELECT p_organization_id, membership.id, 'approval', 'إلغاء حجز يحتاج اعتمادًا', 'يوجد طلب إلغاء حجز ينتظر مراجعة مستقلة.', 'booking', p_booking_id, 'booking-cancel-approval:' || v_approval::text || ':' || membership.id::text
  FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.status = 'active' AND membership.role IN ('owner', 'manager') AND membership.id <> v_actor;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta) VALUES (p_organization_id, 'user', v_actor, 'booking.cancellation_requested', 'booking', p_booking_id, 'success', p_request_id, jsonb_build_object('approval_request_id', v_approval, 'reason', btrim(p_reason)));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'booking.cancellation.requested', 1, 'booking-cancellation:' || v_approval::text, jsonb_build_object('approval_request_id', v_approval, 'booking_id', p_booking_id));
  RETURN v_approval;
END;
$$;

CREATE OR REPLACE FUNCTION public.execute_booking_cancellation(
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
  UPDATE public.bookings SET status = 'cancelled', idempotency_key = NULL, version = version + 1 WHERE organization_id = p_organization_id AND id = p_booking_id;
  UPDATE public.approval_requests SET status = 'executed', executed_at = v_now, updated_at = v_now WHERE organization_id = p_organization_id AND id = v_approval.id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta) VALUES (p_organization_id, 'user', v_actor, 'booking.cancelled', 'booking', p_booking_id, 'success', p_request_id, 'approved', jsonb_build_object('approval_request_id', v_approval.id, 'reason', v_approval.proposal_snapshot->>'reason'));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'booking.cancelled', 1, 'booking-cancelled:' || p_booking_id::text, jsonb_build_object('booking_id', p_booking_id, 'approval_request_id', v_approval.id));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_commercial_booking_stay_event(
  p_organization_id uuid, p_booking_id uuid, p_event_type text, p_notes text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid; v_booking public.bookings%ROWTYPE; v_existing public.booking_stay_events%ROWTYPE; v_id uuid;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'stay event is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_event_type IS NULL OR p_event_type NOT IN ('check_in', 'check_out') OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 OR (p_notes IS NOT NULL AND char_length(btrim(p_notes)) NOT BETWEEN 1 AND 2000) THEN RAISE EXCEPTION 'stay event input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT event.* INTO v_existing FROM public.booking_stay_events AS event WHERE event.organization_id = p_organization_id AND event.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN RETURN v_existing.id; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND OR (p_event_type = 'check_in' AND v_booking.status <> 'confirmed') OR (p_event_type = 'check_out' AND v_booking.status <> 'checked_in') THEN RAISE EXCEPTION 'booking is not ready for this stay event' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.booking_stay_events (organization_id, booking_id, event_type, notes, actor_membership_id, idempotency_key) VALUES (p_organization_id, p_booking_id, p_event_type, NULLIF(btrim(p_notes), ''), v_actor, btrim(p_idempotency_key)) RETURNING id INTO v_id;
  UPDATE public.bookings SET status = CASE WHEN p_event_type = 'check_in' THEN 'checked_in' ELSE 'checked_out' END, version = version + 1 WHERE organization_id = p_organization_id AND id = p_booking_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta) VALUES (p_organization_id, 'user', v_actor, 'booking.' || p_event_type, 'booking', p_booking_id, 'success', p_request_id, jsonb_build_object('event_id', v_id, 'notes', NULLIF(btrim(p_notes), '')));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'booking.' || p_event_type, 1, 'booking-commercial-stay:' || v_id::text, jsonb_build_object('booking_id', p_booking_id, 'event_id', v_id));
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_commercial_booking_draft(uuid, uuid, uuid, date, date, text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.complete_booking_commercial_snapshot(uuid, uuid, text, text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_commercial_booking_work_queue(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_commercial_booking_approval(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.confirm_commercial_booking(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_booking_amendment(uuid, uuid, uuid, uuid, date, date, text, text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.execute_booking_amendment(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_booking_draft(uuid, uuid, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_booking_cancellation(uuid, uuid, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.execute_booking_cancellation(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_commercial_booking_stay_event(uuid, uuid, text, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_commercial_booking_draft(uuid, uuid, uuid, date, date, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_booking_commercial_snapshot(uuid, uuid, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_commercial_booking_work_queue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_commercial_booking_approval(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_commercial_booking(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_booking_amendment(uuid, uuid, uuid, uuid, date, date, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.execute_booking_amendment(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_booking_draft(uuid, uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_booking_cancellation(uuid, uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.execute_booking_cancellation(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_commercial_booking_stay_event(uuid, uuid, text, text, text, uuid) TO authenticated;
