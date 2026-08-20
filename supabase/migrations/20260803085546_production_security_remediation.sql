-- Production security remediation. Forward-only by design: historical
-- migrations may already be applied to remote environments.

-- Fail instead of waiting indefinitely for an incompatible production lock.
-- The managed migration runner supplies the transaction boundary; the local
-- harness also applies every migration with psql --single-transaction.
SET lock_timeout = '5s';
SET statement_timeout = '15min';

-- Auth rate-limit policy is selected by the database. Scope is part of the
-- bucket identity so a direct caller cannot cross-reset another policy bucket.
ALTER TABLE public.auth_rate_limit_buckets
  DROP CONSTRAINT auth_rate_limit_buckets_pkey;
ALTER TABLE public.auth_rate_limit_buckets
  ADD CONSTRAINT auth_rate_limit_buckets_pkey PRIMARY KEY (scope, key_hash);

CREATE OR REPLACE FUNCTION public.consume_auth_rate_limit(
  p_scope text,
  p_key_hash text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_limit integer;
  v_window_seconds integer;
  v_is_allowed boolean;
BEGIN
  CASE p_scope
    WHEN 'magic_link' THEN
      v_limit := 5;
      v_window_seconds := 900;
    WHEN 'password_sign_in' THEN
      v_limit := 10;
      v_window_seconds := 900;
    ELSE
      RAISE EXCEPTION 'unsupported auth rate-limit scope' USING ERRCODE = '22023';
  END CASE;

  IF p_key_hash IS NULL OR p_key_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'auth rate-limit key must be a sha256 hex digest' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.auth_rate_limit_buckets (
    key_hash, scope, window_started_at, attempt_count, updated_at
  ) VALUES (
    p_key_hash, p_scope, v_now, 1, v_now
  )
  ON CONFLICT (scope, key_hash) DO UPDATE
  SET
    window_started_at = CASE
      WHEN public.auth_rate_limit_buckets.window_started_at
        + make_interval(secs => v_window_seconds) <= v_now
        THEN v_now
      ELSE public.auth_rate_limit_buckets.window_started_at
    END,
    attempt_count = CASE
      WHEN public.auth_rate_limit_buckets.window_started_at
        + make_interval(secs => v_window_seconds) <= v_now
        THEN 1
      ELSE public.auth_rate_limit_buckets.attempt_count + 1
    END,
    updated_at = v_now
  RETURNING attempt_count <= v_limit INTO v_is_allowed;

  RETURN v_is_allowed;
END;
$$;

-- Rolling-deploy compatibility for the previous application signature. The
-- legacy arguments are accepted only when they exactly match trusted policy;
-- they never participate in bucket calculation.
CREATE OR REPLACE FUNCTION public.consume_auth_rate_limit(
  p_scope text,
  p_key_hash text,
  p_limit integer,
  p_window_seconds integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_expected_limit integer;
  v_expected_window_seconds integer := 900;
BEGIN
  CASE p_scope
    WHEN 'magic_link' THEN v_expected_limit := 5;
    WHEN 'password_sign_in' THEN v_expected_limit := 10;
    ELSE
      RAISE EXCEPTION 'unsupported auth rate-limit scope' USING ERRCODE = '22023';
  END CASE;

  IF p_limit IS DISTINCT FROM v_expected_limit
    OR p_window_seconds IS DISTINCT FROM v_expected_window_seconds THEN
    RAISE EXCEPTION 'auth rate-limit policy is database controlled' USING ERRCODE = '22023';
  END IF;

  RETURN public.consume_auth_rate_limit(p_scope, p_key_hash);
END;
$$;

CREATE OR REPLACE FUNCTION public.purge_auth_rate_limit_buckets(
  p_retention_seconds integer,
  p_limit integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_deleted_count integer;
BEGIN
  IF p_retention_seconds IS NULL
    OR p_retention_seconds < 3600
    OR p_retention_seconds > 31536000 THEN
    RAISE EXCEPTION 'auth rate-limit retention must be between 3600 and 31536000 seconds' USING ERRCODE = '22023';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
    RAISE EXCEPTION 'auth rate-limit purge limit must be between 1 and 1000' USING ERRCODE = '22023';
  END IF;

  WITH expired AS (
    SELECT scope, key_hash
    FROM public.auth_rate_limit_buckets
    WHERE updated_at < clock_timestamp() - make_interval(secs => p_retention_seconds)
    ORDER BY updated_at ASC, scope, key_hash
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.auth_rate_limit_buckets AS bucket
  USING expired
  WHERE bucket.scope = expired.scope
    AND bucket.key_hash = expired.key_hash;

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  RETURN v_deleted_count;
END;
$$;

REVOKE ALL ON FUNCTION public.consume_auth_rate_limit(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.consume_auth_rate_limit(text, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_auth_rate_limit_buckets(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consume_auth_rate_limit(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_auth_rate_limit(text, text, integer, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_auth_rate_limit_buckets(integer, integer) TO voya_outbox_worker;

-- Persist the command identity separately from mutable workflow state. Approval
-- requests may renew after expiry, while a booking confirmation binds to one
-- logical idempotency key for its lifetime.
CREATE TABLE public.booking_command_idempotency (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  command_name text NOT NULL CHECK (command_name IN ('booking.approval.request', 'booking.confirm')),
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  booking_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT booking_command_idempotency_pkey
    PRIMARY KEY (organization_id, command_name, idempotency_key),
  CONSTRAINT booking_command_idempotency_booking_tenant_fk
    FOREIGN KEY (organization_id, booking_id)
    REFERENCES public.bookings(organization_id, id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX booking_confirm_command_once_idx
  ON public.booking_command_idempotency (organization_id, booking_id)
  WHERE command_name = 'booking.confirm';
CREATE INDEX booking_command_idempotency_booking_idx
  ON public.booking_command_idempotency (organization_id, booking_id, command_name);
ALTER TABLE public.booking_command_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.booking_command_idempotency FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.booking_command_idempotency FROM PUBLIC;

-- Parent-side tenant keys required by composite foreign keys.
ALTER TABLE public.leads
  ADD CONSTRAINT leads_organization_id_id_unique UNIQUE (organization_id, id);
ALTER TABLE public.crm_contact_methods
  ADD CONSTRAINT crm_contact_methods_organization_id_id_unique UNIQUE (organization_id, id);
ALTER TABLE public.whatsapp_conversations
  ADD CONSTRAINT whatsapp_conversations_organization_id_id_unique UNIQUE (organization_id, id);

-- Add and validate tenant-qualified relationships before removing the unsafe
-- single-column foreign keys. Existing cross-tenant rows make this migration
-- fail closed rather than being silently rewritten.
ALTER TABLE public.crm_contact_methods
  ADD CONSTRAINT crm_contact_method_lead_tenant_fk
  FOREIGN KEY (organization_id, lead_id)
  REFERENCES public.leads(organization_id, id) ON DELETE RESTRICT NOT VALID,
  ADD CONSTRAINT crm_contact_method_client_tenant_fk
  FOREIGN KEY (organization_id, client_id)
  REFERENCES public.clients(organization_id, id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.crm_contact_methods
  VALIDATE CONSTRAINT crm_contact_method_lead_tenant_fk;
ALTER TABLE public.crm_contact_methods
  VALIDATE CONSTRAINT crm_contact_method_client_tenant_fk;
ALTER TABLE public.crm_contact_methods
  DROP CONSTRAINT crm_contact_methods_lead_id_fkey,
  DROP CONSTRAINT crm_contact_methods_client_id_fkey;

ALTER TABLE public.crm_consent_events
  ADD CONSTRAINT crm_consent_contact_method_tenant_fk
  FOREIGN KEY (organization_id, contact_method_id)
  REFERENCES public.crm_contact_methods(organization_id, id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.crm_consent_events
  VALIDATE CONSTRAINT crm_consent_contact_method_tenant_fk;
ALTER TABLE public.crm_consent_events
  DROP CONSTRAINT crm_consent_events_contact_method_id_fkey;

ALTER TABLE public.whatsapp_conversations
  ADD CONSTRAINT whatsapp_conversation_contact_method_tenant_fk
  FOREIGN KEY (organization_id, contact_method_id)
  REFERENCES public.crm_contact_methods(organization_id, id) ON DELETE RESTRICT NOT VALID,
  ADD CONSTRAINT whatsapp_conversation_lead_tenant_fk
  FOREIGN KEY (organization_id, lead_id)
  REFERENCES public.leads(organization_id, id) ON DELETE RESTRICT NOT VALID,
  ADD CONSTRAINT whatsapp_conversation_client_tenant_fk
  FOREIGN KEY (organization_id, client_id)
  REFERENCES public.clients(organization_id, id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.whatsapp_conversations
  VALIDATE CONSTRAINT whatsapp_conversation_contact_method_tenant_fk;
ALTER TABLE public.whatsapp_conversations
  VALIDATE CONSTRAINT whatsapp_conversation_lead_tenant_fk;
ALTER TABLE public.whatsapp_conversations
  VALIDATE CONSTRAINT whatsapp_conversation_client_tenant_fk;
ALTER TABLE public.whatsapp_conversations
  DROP CONSTRAINT whatsapp_conversations_channel_id_fkey,
  DROP CONSTRAINT whatsapp_conversations_contact_method_id_fkey,
  DROP CONSTRAINT whatsapp_conversations_lead_id_fkey,
  DROP CONSTRAINT whatsapp_conversations_client_id_fkey;

ALTER TABLE public.whatsapp_message_events
  ADD CONSTRAINT whatsapp_message_conversation_tenant_fk
  FOREIGN KEY (organization_id, conversation_id)
  REFERENCES public.whatsapp_conversations(organization_id, id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.whatsapp_message_events
  VALIDATE CONSTRAINT whatsapp_message_conversation_tenant_fk;
ALTER TABLE public.whatsapp_message_events
  DROP CONSTRAINT whatsapp_message_events_conversation_id_fkey;

ALTER TABLE public.whatsapp_internal_notes
  ADD CONSTRAINT whatsapp_note_conversation_tenant_fk
  FOREIGN KEY (organization_id, conversation_id)
  REFERENCES public.whatsapp_conversations(organization_id, id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.whatsapp_internal_notes
  VALIDATE CONSTRAINT whatsapp_note_conversation_tenant_fk;
ALTER TABLE public.whatsapp_internal_notes
  DROP CONSTRAINT whatsapp_internal_notes_conversation_id_fkey;

ALTER TABLE public.operations_tasks
  ADD CONSTRAINT operations_task_booking_tenant_fk
  FOREIGN KEY (organization_id, booking_id)
  REFERENCES public.bookings(organization_id, id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.operations_tasks
  VALIDATE CONSTRAINT operations_task_booking_tenant_fk;
ALTER TABLE public.operations_tasks
  DROP CONSTRAINT operations_tasks_booking_id_fkey;

CREATE INDEX whatsapp_conversations_contact_method_idx
  ON public.whatsapp_conversations (organization_id, contact_method_id)
  WHERE contact_method_id IS NOT NULL;
CREATE INDEX whatsapp_conversations_lead_idx
  ON public.whatsapp_conversations (organization_id, lead_id)
  WHERE lead_id IS NOT NULL;
CREATE INDEX whatsapp_conversations_client_idx
  ON public.whatsapp_conversations (organization_id, client_id)
  WHERE client_id IS NOT NULL;

-- Active allocations occupy [pickup_at, return_at). A NULL return_at is an
-- intentionally conservative unbounded interval and is released only when the
-- request becomes completed or cancelled.
ALTER TABLE public.transport_requests
  ADD CONSTRAINT transport_vehicle_active_allocation_excl
  EXCLUDE USING gist (
    organization_id WITH =,
    vehicle_id WITH =,
    tstzrange(pickup_at, return_at, '[)') WITH &&
  ) WHERE (status IN ('assigned', 'in_progress') AND vehicle_id IS NOT NULL),
  ADD CONSTRAINT transport_driver_active_allocation_excl
  EXCLUDE USING gist (
    organization_id WITH =,
    driver_id WITH =,
    tstzrange(pickup_at, return_at, '[)') WITH &&
  ) WHERE (status IN ('assigned', 'in_progress') AND driver_id IS NOT NULL);

CREATE OR REPLACE FUNCTION public.request_booking_approval(
  p_organization_id uuid,
  p_booking_id uuid,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
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
    -- Serialize every still-actionable approval for this booking. Historical
    -- data may contain more than one row even though the command path does not.
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
      -- Preserve one valid request and explicitly supersede any historical
      -- duplicate so retries have one deterministic result.
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
    'property_id', v_booking.property_id,
    'client_id', v_booking.client_id,
    'check_in', v_booking.check_in,
    'check_out', v_booking.check_out,
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
SET search_path = pg_catalog
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
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
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

  v_snapshot := jsonb_build_object(
    'booking_id', v_booking.id,
    'property_id', v_booking.property_id,
    'client_id', v_booking.client_id,
    'check_in', v_booking.check_in,
    'check_out', v_booking.check_out,
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
  SET status = 'confirmed', idempotency_key = NULL
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
    jsonb_build_object('approval_request_id', v_approval.id)
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

CREATE OR REPLACE FUNCTION public.record_booking_stay_event(
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
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_booking public.bookings%ROWTYPE;
  v_existing public.booking_stay_events%ROWTYPE;
  v_notes text := NULLIF(btrim(p_notes), '');
  v_event uuid;
BEGIN
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
    OR p_idempotency_key IS NULL
    OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160
    OR (p_notes IS NOT NULL AND (v_notes IS NULL OR char_length(v_notes) > 2000)) THEN
    RAISE EXCEPTION 'stay event input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503';
  END IF;

  SELECT stay_event.* INTO v_existing
  FROM public.booking_stay_events AS stay_event
  WHERE stay_event.organization_id = p_organization_id
    AND stay_event.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.booking_id = p_booking_id
      AND v_existing.event_type = p_event_type
      AND v_existing.notes IS NOT DISTINCT FROM v_notes THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'stay-event idempotency key belongs to a different command' USING ERRCODE = '23505';
  END IF;

  IF v_booking.status <> 'confirmed' THEN
    RAISE EXCEPTION 'booking is not ready for a stay event' USING ERRCODE = '22023';
  END IF;
  IF p_event_type = 'check_out' AND NOT EXISTS (
    SELECT 1 FROM public.booking_stay_events AS stay_event
    WHERE stay_event.organization_id = p_organization_id
      AND stay_event.booking_id = p_booking_id
      AND stay_event.event_type = 'check_in'
  ) THEN
    RAISE EXCEPTION 'check-in is required before check-out' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.booking_stay_events (
    organization_id, booking_id, event_type, notes,
    actor_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, p_booking_id, p_event_type, v_notes,
    v_actor, btrim(p_idempotency_key)
  ) RETURNING id INTO v_event;

  IF p_event_type = 'check_out' THEN
    UPDATE public.bookings
    SET status = 'completed'
    WHERE organization_id = p_organization_id
      AND id = p_booking_id;
  END IF;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.' || p_event_type,
    'booking', p_booking_id, 'success', p_request_id,
    jsonb_build_object('event_id', v_event, 'notes', v_notes)
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'booking.' || p_event_type, 1,
    'booking-stay-event:' || v_event::text,
    jsonb_build_object('booking_id', p_booking_id, 'event_id', v_event)
  );
  RETURN v_event;
END;
$$;

CREATE OR REPLACE FUNCTION public.add_whatsapp_internal_note(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_note_text text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_role text;
  v_id uuid;
BEGIN
  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'note creation is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_note_text IS NULL
    OR char_length(btrim(p_note_text)) NOT BETWEEN 1 AND 4096 THEN
    RAISE EXCEPTION 'note input is invalid' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.whatsapp_conversations AS conversation
    WHERE conversation.id = p_conversation_id
      AND conversation.organization_id = p_organization_id
      AND (
        v_role IN ('owner', 'manager')
        OR conversation.assigned_membership_id IS NULL
        OR conversation.assigned_membership_id = v_actor
      )
  ) THEN
    RAISE EXCEPTION 'conversation is not permitted' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.whatsapp_internal_notes (
    organization_id, conversation_id, note_text, created_by_membership_id
  ) VALUES (
    p_organization_id, p_conversation_id, btrim(p_note_text), v_actor
  ) RETURNING id INTO v_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'whatsapp.note.created',
    'whatsapp_internal_note', v_id, 'success', p_request_id,
    jsonb_build_object('conversation_id', p_conversation_id)
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.assign_transport_request(
  p_organization_id uuid,
  p_request_id uuid,
  p_vehicle_id uuid DEFAULT NULL,
  p_driver_id uuid DEFAULT NULL,
  p_request_idempotency uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_old public.transport_requests%ROWTYPE;
  v_new_status text;
  v_assignment_event_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'transport assignment is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT request.* INTO v_old
  FROM public.transport_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transport request is invalid' USING ERRCODE = '23503';
  END IF;
  IF v_old.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'transport request cannot be assigned in its current state' USING ERRCODE = '22023';
  END IF;
  IF v_old.status = 'in_progress'
    AND p_vehicle_id IS NULL
    AND p_driver_id IS NULL THEN
    RAISE EXCEPTION 'in-progress transport cannot release every assigned resource' USING ERRCODE = '22023';
  END IF;
  IF p_vehicle_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.fleet_vehicles AS vehicle
    WHERE vehicle.organization_id = p_organization_id
      AND vehicle.id = p_vehicle_id
      AND vehicle.status = 'available'
  ) THEN
    RAISE EXCEPTION 'transport vehicle is not available' USING ERRCODE = '23503';
  END IF;
  IF p_driver_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.fleet_drivers AS driver
    WHERE driver.organization_id = p_organization_id
      AND driver.id = p_driver_id
      AND driver.status = 'available'
  ) THEN
    RAISE EXCEPTION 'transport driver is not available' USING ERRCODE = '23503';
  END IF;

  v_new_status := CASE
    WHEN v_old.status = 'in_progress' THEN 'in_progress'
    WHEN p_vehicle_id IS NULL AND p_driver_id IS NULL THEN 'requested'
    ELSE 'assigned'
  END;
  IF v_old.vehicle_id IS NOT DISTINCT FROM p_vehicle_id
    AND v_old.driver_id IS NOT DISTINCT FROM p_driver_id
    AND v_old.status = v_new_status THEN
    RETURN true;
  END IF;

  UPDATE public.transport_requests
  SET vehicle_id = p_vehicle_id,
      driver_id = p_driver_id,
      status = v_new_status
  WHERE id = p_request_id
    AND organization_id = p_organization_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'transport.request.assigned',
    'transport_request', p_request_id, 'success', p_request_idempotency,
    jsonb_build_object(
      'vehicle_id', v_old.vehicle_id,
      'driver_id', v_old.driver_id,
      'status', v_old.status
    ),
    jsonb_build_object(
      'vehicle_id', p_vehicle_id,
      'driver_id', p_driver_id,
      'status', v_new_status
    )
  );
  v_assignment_event_id := extensions.gen_random_uuid();
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'transport.request.assigned', 1,
    'transport-assignment:' || p_request_id::text || ':' || v_assignment_event_id::text,
    jsonb_build_object(
      'transport_request_id', p_request_id,
      'assignment_event_id', v_assignment_event_id
    )
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_transport_request_status(
  p_organization_id uuid,
  p_request_id uuid,
  p_status text,
  p_request_idempotency uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_old text;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'transport status update is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_status IS NULL
    OR p_status NOT IN ('requested', 'assigned', 'in_progress', 'completed', 'cancelled') THEN
    RAISE EXCEPTION 'transport status is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT request.status INTO v_old
  FROM public.transport_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transport request is invalid' USING ERRCODE = '23503';
  END IF;
  IF v_old = p_status THEN
    RETURN true;
  END IF;
  IF NOT (
    (v_old = 'requested' AND p_status IN ('in_progress', 'cancelled'))
    OR (v_old = 'assigned' AND p_status IN ('in_progress', 'cancelled'))
    OR (v_old = 'in_progress' AND p_status IN ('completed', 'cancelled'))
  ) THEN
    RAISE EXCEPTION 'transport status transition is invalid' USING ERRCODE = '22023';
  END IF;

  UPDATE public.transport_requests
  SET status = p_status
  WHERE id = p_request_id
    AND organization_id = p_organization_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'transport.request.status_changed',
    'transport_request', p_request_id, 'success', p_request_idempotency,
    jsonb_build_object('status', v_old), jsonb_build_object('status', p_status)
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_operations_task_status(
  p_organization_id uuid,
  p_task_id uuid,
  p_status text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_old text;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'task update is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_status IS NULL
    OR p_status NOT IN ('open', 'in_progress', 'completed', 'cancelled') THEN
    RAISE EXCEPTION 'task status is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT task.status INTO v_old
  FROM public.operations_tasks AS task
  WHERE task.id = p_task_id
    AND task.organization_id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'task is invalid' USING ERRCODE = '23503';
  END IF;
  IF v_old = p_status THEN
    RETURN true;
  END IF;
  IF NOT (
    (v_old = 'open' AND p_status IN ('in_progress', 'completed', 'cancelled'))
    OR (v_old = 'in_progress' AND p_status IN ('completed', 'cancelled'))
  ) THEN
    RAISE EXCEPTION 'task status transition is invalid' USING ERRCODE = '22023';
  END IF;

  UPDATE public.operations_tasks
  SET status = p_status
  WHERE id = p_task_id
    AND organization_id = p_organization_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'operations.task.status_changed',
    'operations_task', p_task_id, 'success', p_request_id,
    jsonb_build_object('status', v_old), jsonb_build_object('status', p_status)
  );
  RETURN true;
END;
$$;

-- Reassert least-privilege execution after replacing security-definer bodies.
REVOKE ALL ON FUNCTION public.request_booking_approval(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.confirm_booking(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_booking_stay_event(uuid, uuid, text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_whatsapp_internal_note(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assign_transport_request(uuid, uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_transport_request_status(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_operations_task_status(uuid, uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_booking_approval(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_booking(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_booking_stay_event(uuid, uuid, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_whatsapp_internal_note(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assign_transport_request(uuid, uuid, uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_transport_request_status(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_operations_task_status(uuid, uuid, text, uuid) TO authenticated;

RESET statement_timeout;
RESET lock_timeout;
;

