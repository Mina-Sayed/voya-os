-- Forward-only hardening for authentication bootstrap and command reliability.

-- Repeat fresh-restore dependencies here so already-migrated environments do
-- not depend on applying the compatibility migration out of timestamp order.
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_extension AS extension
    JOIN pg_namespace AS namespace ON namespace.oid = extension.extnamespace
    WHERE extension.extname = 'pgcrypto'
      AND namespace.nspname <> 'extensions'
  ) THEN
    EXECUTE 'ALTER EXTENSION pgcrypto SET SCHEMA extensions';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'voya_outbox_worker') THEN
    CREATE ROLE voya_outbox_worker NOLOGIN;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_crm_contact_method(
  p_organization_id uuid,
  p_kind text,
  p_normalized_value text,
  p_display_value text,
  p_lead_id uuid DEFAULT NULL,
  p_client_id uuid DEFAULT NULL,
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
  v_idempotency_key text := btrim(p_idempotency_key);
  v_existing public.crm_contact_methods%ROWTYPE;
  v_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'contact method creation is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('email', 'phone', 'whatsapp')
    OR p_normalized_value IS NULL OR char_length(btrim(p_normalized_value)) NOT BETWEEN 1 AND 320
    OR p_display_value IS NULL OR char_length(btrim(p_display_value)) NOT BETWEEN 1 AND 320
    OR v_idempotency_key IS NULL OR char_length(v_idempotency_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'contact method input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_lead_id IS NULL AND p_client_id IS NULL THEN
    RAISE EXCEPTION 'contact method must be linked to a lead or client' USING ERRCODE = '22023';
  END IF;
  IF p_lead_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.leads WHERE id = p_lead_id AND organization_id = p_organization_id
  ) THEN
    RAISE EXCEPTION 'contact lead is invalid' USING ERRCODE = '23503';
  END IF;
  IF p_client_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.clients WHERE id = p_client_id AND organization_id = p_organization_id
  ) THEN
    RAISE EXCEPTION 'contact client is invalid' USING ERRCODE = '23503';
  END IF;

  INSERT INTO public.crm_contact_methods (
    organization_id, lead_id, client_id, kind, normalized_value,
    display_value, idempotency_key, created_by_membership_id
  ) VALUES (
    p_organization_id, p_lead_id, p_client_id, p_kind, btrim(p_normalized_value),
    btrim(p_display_value), v_idempotency_key, v_actor
  )
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT contact.* INTO v_existing
    FROM public.crm_contact_methods AS contact
    WHERE contact.organization_id = p_organization_id
      AND contact.idempotency_key = v_idempotency_key;
    IF NOT FOUND
      OR v_existing.kind <> p_kind
      OR v_existing.normalized_value <> btrim(p_normalized_value)
      OR v_existing.display_value <> btrim(p_display_value)
      OR v_existing.lead_id IS DISTINCT FROM p_lead_id
      OR v_existing.client_id IS DISTINCT FROM p_client_id THEN
      RAISE EXCEPTION 'idempotency key belongs to a different contact method' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'crm.contact_method.created', 'crm_contact_method',
    v_id, 'success', p_request_id,
    jsonb_build_object('kind', p_kind, 'lead_id', p_lead_id, 'client_id', p_client_id)
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_whatsapp_message(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_body_text text,
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
  v_idempotency_key text := btrim(p_idempotency_key);
  v_existing public.whatsapp_message_events%ROWTYPE;
  v_id uuid;
  v_event_key text;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'message creation is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_body_text IS NULL OR char_length(btrim(p_body_text)) NOT BETWEEN 1 AND 4096
    OR v_idempotency_key IS NULL OR char_length(v_idempotency_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'message input is invalid' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.whatsapp_conversations AS conversation
    JOIN public.whatsapp_channels AS channel
      ON channel.id = conversation.channel_id AND channel.organization_id = conversation.organization_id
    WHERE conversation.id = p_conversation_id AND conversation.organization_id = p_organization_id
      AND conversation.status <> 'closed'
      AND channel.status = 'active' AND channel.kill_switch = false
      AND (conversation.assigned_membership_id IS NULL OR conversation.assigned_membership_id = v_actor OR EXISTS (
        SELECT 1 FROM public.organization_memberships WHERE id = v_actor AND role IN ('owner', 'manager')
      ))
  ) THEN
    RAISE EXCEPTION 'conversation is unavailable' USING ERRCODE = '42501';
  END IF;

  v_event_key := 'manual:' || extensions.gen_random_uuid()::text;
  INSERT INTO public.whatsapp_message_events (
    organization_id, conversation_id, event_key, direction, body_text,
    delivery_status, created_by_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, p_conversation_id, v_event_key, 'outbound', btrim(p_body_text),
    'queued', v_actor, v_idempotency_key
  )
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT message.* INTO v_existing
    FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = p_organization_id
      AND message.idempotency_key = v_idempotency_key;
    IF NOT FOUND
      OR v_existing.body_text <> btrim(p_body_text)
      OR v_existing.conversation_id <> p_conversation_id THEN
      RAISE EXCEPTION 'idempotency key belongs to a different message' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  UPDATE public.whatsapp_conversations
  SET last_message_at = timezone('utc', now())
  WHERE id = p_conversation_id AND organization_id = p_organization_id;

  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'whatsapp.message.send_requested', 1, 'whatsapp-message:' || v_id::text,
    jsonb_build_object('message_id', v_id, 'conversation_id', p_conversation_id)
  );
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'whatsapp.message.queued', 'whatsapp_message_event',
    v_id, 'success', p_request_id, jsonb_build_object('conversation_id', p_conversation_id)
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_ai_run_request(
  p_organization_id uuid,
  p_agent_kind text,
  p_purpose text,
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
  v_role text;
  v_idempotency_key text := btrim(p_idempotency_key);
  v_existing public.ai_runs%ROWTYPE;
  v_id uuid;
  v_agent_allowed boolean := false;
BEGIN
  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'AI run request is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_agent_kind IS NULL OR p_agent_kind NOT IN ('sales', 'booking', 'finance', 'manager')
    OR p_purpose IS NULL OR char_length(btrim(p_purpose)) NOT BETWEEN 1 AND 280
    OR v_idempotency_key IS NULL OR char_length(v_idempotency_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI run request is invalid' USING ERRCODE = '22023';
  END IF;
  v_agent_allowed := CASE
    WHEN p_agent_kind = 'sales' THEN v_role IN ('owner', 'manager', 'sales_agent')
    WHEN p_agent_kind = 'booking' THEN v_role IN ('owner', 'manager', 'sales_agent', 'operations')
    WHEN p_agent_kind = 'manager' THEN v_role IN ('owner', 'manager')
    ELSE false
  END;
  IF NOT v_agent_allowed THEN
    RAISE EXCEPTION 'AI agent is disabled or not permitted' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.ai_runs (
    organization_id, agent_kind, agent_version, status, purpose,
    model_name, prompt_version, initiated_by_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, p_agent_kind, 'registry-v1', 'queued', btrim(p_purpose),
    'unconfigured', 'unconfigured', v_actor, v_idempotency_key
  )
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT run.* INTO v_existing
    FROM public.ai_runs AS run
    WHERE run.organization_id = p_organization_id
      AND run.idempotency_key = v_idempotency_key;
    IF NOT FOUND
      OR v_existing.agent_kind <> p_agent_kind
      OR v_existing.purpose <> btrim(p_purpose) THEN
      RAISE EXCEPTION 'AI run idempotency key belongs to a different request' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'ai.run.requested', 1, 'ai-run:' || v_id::text,
    jsonb_build_object('run_id', v_id, 'agent_kind', p_agent_kind)
  );
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.run.requested', 'ai_run',
    v_id, 'success', p_request_id, jsonb_build_object('agent_kind', p_agent_kind, 'status', 'queued')
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_operations_task(
  p_organization_id uuid,
  p_task_type text,
  p_title text,
  p_description text DEFAULT NULL,
  p_due_at timestamptz DEFAULT NULL,
  p_booking_id uuid DEFAULT NULL,
  p_assigned_membership_id uuid DEFAULT NULL,
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
  v_idempotency_key text := btrim(p_idempotency_key);
  v_existing public.operations_tasks%ROWTYPE;
  v_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'task creation is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_task_type IS NULL OR p_task_type !~ '^[a-z][a-z0-9_.-]{0,79}$'
    OR p_title IS NULL OR char_length(btrim(p_title)) NOT BETWEEN 1 AND 200
    OR (p_description IS NOT NULL AND char_length(btrim(p_description)) NOT BETWEEN 1 AND 2000)
    OR v_idempotency_key IS NULL OR char_length(v_idempotency_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'task input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_booking_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.bookings WHERE id = p_booking_id AND organization_id = p_organization_id
  ) THEN
    RAISE EXCEPTION 'task booking is invalid' USING ERRCODE = '23503';
  END IF;
  IF p_assigned_membership_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.organization_memberships
    WHERE id = p_assigned_membership_id AND organization_id = p_organization_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'task assignee is invalid' USING ERRCODE = '23503';
  END IF;

  INSERT INTO public.operations_tasks (
    organization_id, task_type, title, description, due_at, booking_id,
    assigned_membership_id, created_by_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, p_task_type, btrim(p_title), NULLIF(btrim(p_description), ''), p_due_at,
    p_booking_id, p_assigned_membership_id, v_actor, v_idempotency_key
  )
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT task.* INTO v_existing
    FROM public.operations_tasks AS task
    WHERE task.organization_id = p_organization_id
      AND task.idempotency_key = v_idempotency_key;
    IF NOT FOUND
      OR v_existing.task_type <> p_task_type
      OR v_existing.title <> btrim(p_title)
      OR v_existing.description IS DISTINCT FROM NULLIF(btrim(p_description), '')
      OR v_existing.due_at IS DISTINCT FROM p_due_at
      OR v_existing.booking_id IS DISTINCT FROM p_booking_id
      OR v_existing.assigned_membership_id IS DISTINCT FROM p_assigned_membership_id THEN
      RAISE EXCEPTION 'task idempotency key belongs to a different task' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'operations.task.created', 'operations_task',
    v_id, 'success', p_request_id, jsonb_build_object('task_type', p_task_type, 'booking_id', p_booking_id)
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'operations.task.created', 1, 'operations-task:' || v_id::text,
    jsonb_build_object('task_id', v_id)
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_transport_request(
  p_organization_id uuid,
  p_request_type text,
  p_guest_label text,
  p_pickup_location text,
  p_dropoff_location text,
  p_pickup_at timestamptz,
  p_passenger_count integer DEFAULT 1,
  p_return_at timestamptz DEFAULT NULL,
  p_booking_id uuid DEFAULT NULL,
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
  v_idempotency_key text := btrim(p_idempotency_key);
  v_existing public.transport_requests%ROWTYPE;
  v_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'transport request creation is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_request_type IS NULL OR p_request_type NOT IN ('airport_transfer', 'car_rental')
    OR p_guest_label IS NULL OR char_length(btrim(p_guest_label)) NOT BETWEEN 1 AND 160
    OR p_pickup_location IS NULL OR char_length(btrim(p_pickup_location)) NOT BETWEEN 1 AND 240
    OR p_dropoff_location IS NULL OR char_length(btrim(p_dropoff_location)) NOT BETWEEN 1 AND 240
    OR p_pickup_at IS NULL OR p_passenger_count IS NULL OR p_passenger_count NOT BETWEEN 1 AND 80
    OR (p_return_at IS NOT NULL AND p_return_at <= p_pickup_at)
    OR (p_notes IS NOT NULL AND char_length(btrim(p_notes)) NOT BETWEEN 1 AND 2000)
    OR v_idempotency_key IS NULL OR char_length(v_idempotency_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'transport request input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_booking_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.bookings AS booking
    WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id
  ) THEN
    RAISE EXCEPTION 'transport booking is invalid' USING ERRCODE = '23503';
  END IF;

  INSERT INTO public.transport_requests (
    organization_id, request_type, guest_label, pickup_location, dropoff_location,
    pickup_at, return_at, passenger_count, booking_id, notes,
    created_by_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, p_request_type, btrim(p_guest_label), btrim(p_pickup_location),
    btrim(p_dropoff_location), p_pickup_at, p_return_at, p_passenger_count,
    p_booking_id, NULLIF(btrim(p_notes), ''), v_actor, v_idempotency_key
  )
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT request.* INTO v_existing
    FROM public.transport_requests AS request
    WHERE request.organization_id = p_organization_id
      AND request.idempotency_key = v_idempotency_key;
    IF NOT FOUND
      OR v_existing.request_type <> p_request_type
      OR v_existing.guest_label <> btrim(p_guest_label)
      OR v_existing.pickup_location <> btrim(p_pickup_location)
      OR v_existing.dropoff_location <> btrim(p_dropoff_location)
      OR v_existing.pickup_at <> p_pickup_at
      OR v_existing.return_at IS DISTINCT FROM p_return_at
      OR v_existing.passenger_count <> p_passenger_count
      OR v_existing.booking_id IS DISTINCT FROM p_booking_id
      OR v_existing.notes IS DISTINCT FROM NULLIF(btrim(p_notes), '') THEN
      RAISE EXCEPTION 'transport idempotency key belongs to a different request' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'transport.request.created', 'transport_request',
    v_id, 'success', p_request_id,
    jsonb_build_object('request_type', p_request_type, 'passenger_count', p_passenger_count)
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'transport.request.created', 1, 'transport-request:' || v_id::text,
    jsonb_build_object('transport_request_id', v_id)
  );
  RETURN v_id;
END;
$$;

-- The application now calls this function only through a server-side client.
REVOKE ALL ON FUNCTION public.consume_auth_rate_limit(text, text)
  FROM PUBLIC, anon, authenticated, voya_outbox_worker;
GRANT EXECUTE ON FUNCTION public.consume_auth_rate_limit(text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.bootstrap_personal_workspace(p_request_id uuid DEFAULT NULL)
RETURNS TABLE (organization_id uuid, membership_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_membership_id uuid;
  v_organization_created boolean := false;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authenticated user required' USING ERRCODE = '42501';
  END IF;

  -- Lock the canonical Auth row first. This both verifies confirmation without
  -- trusting a JWT email claim and serializes concurrent bootstrap attempts.
  PERFORM user_record.id
  FROM auth.users AS user_record
  WHERE user_record.id = v_user_id
    AND user_record.email_confirmed_at IS NOT NULL
    AND user_record.email IS NOT NULL
    AND btrim(user_record.email) <> ''
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'verified email required' USING ERRCODE = '42501';
  END IF;

  -- Any prior membership is an access-state decision, not an invitation to
  -- create a second personal workspace. Pending and suspended rows count too.
  IF EXISTS (
    SELECT 1
    FROM public.organization_memberships AS membership
    WHERE membership.user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'workspace bootstrap is not permitted' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.profiles (id, display_name, locale)
  VALUES (v_user_id, 'Voya Operator', 'ar')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.organizations (name, slug, default_locale, timezone, status)
  VALUES (
    'Voya Workspace',
    'workspace-' || replace(v_user_id::text, '-', ''),
    'ar',
    'Africa/Cairo',
    'active'
  )
  ON CONFLICT (slug) DO NOTHING
  RETURNING id INTO v_organization_id;

  v_organization_created := v_organization_id IS NOT NULL;

  IF NOT v_organization_created THEN
    SELECT organization.id
    INTO v_organization_id
    FROM public.organizations AS organization
    WHERE organization.slug = 'workspace-' || replace(v_user_id::text, '-', '')
    FOR UPDATE;
  END IF;

  IF v_organization_id IS NULL THEN
    RAISE EXCEPTION 'workspace bootstrap could not resolve organization' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
  VALUES (v_organization_id, v_user_id, 'owner', 'active')
  RETURNING id INTO v_membership_id;

  INSERT INTO public.audit_events (
    organization_id,
    actor_type,
    actor_membership_id,
    action,
    resource_type,
    resource_id,
    outcome,
    request_id,
    reason_code,
    after_delta
  )
  VALUES (
    v_organization_id,
    'user',
    v_membership_id,
    'organization.bootstrap',
    'organization',
    v_organization_id,
    'success',
    p_request_id,
    'self_service_verified_email',
    jsonb_build_object('source', 'self_service', 'role', 'owner')
  );

  RETURN QUERY SELECT v_organization_id, v_membership_id;
END;
$$;

REVOKE ALL ON FUNCTION public.bootstrap_personal_workspace(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bootstrap_personal_workspace(uuid) TO authenticated;

COMMENT ON FUNCTION public.bootstrap_personal_workspace(uuid)
IS 'Creates one private workspace only for a confirmed authenticated user with no membership of any status.';

-- Every booking approval path now locks the booking before its approval row.
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

  -- Resolve the booking identity without a lock, then acquire locks in the
  -- same booking -> approval order used by request and confirmation commands.
  SELECT request.resource_id INTO v_booking_id
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_approval_request_id
    AND request.resource_type = 'booking'
    AND request.proposed_action = 'booking.confirm';
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
    AND request.proposed_action = 'booking.confirm'
  FOR UPDATE;
  IF NOT FOUND
    OR v_request.resource_id <> v_booking.id
    OR v_request.status <> 'pending'
    OR (v_request.expires_at IS NOT NULL AND v_request.expires_at <= timezone('utc', now())) THEN
    RAISE EXCEPTION 'approval request is no longer actionable' USING ERRCODE = '22023';
  END IF;
  IF v_request.requester_membership_id = v_actor THEN
    RAISE EXCEPTION 'requester cannot approve their own booking' USING ERRCODE = '42501';
  END IF;
  IF v_booking.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'booking is no longer awaiting approval' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.approval_decisions (
    organization_id, approval_request_id, approver_membership_id, decision, reason
  ) VALUES (
    p_organization_id, p_approval_request_id, v_actor, p_decision, btrim(p_reason)
  );
  UPDATE public.approval_requests
  SET status = p_decision, updated_at = timezone('utc', now())
  WHERE organization_id = p_organization_id AND id = p_approval_request_id;
  IF p_decision = 'rejected' THEN
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
    jsonb_build_object('approval_request_id', p_approval_request_id, 'reason', btrim(p_reason))
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id,
    'booking.approval.' || p_decision,
    1,
    'booking-approval-decision:' || p_approval_request_id::text || ':' || p_decision,
    jsonb_build_object('approval_request_id', p_approval_request_id, 'booking_id', v_request.resource_id)
  );
  RETURN true;
END;
$$;
