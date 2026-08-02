-- Voya OS: tenant-scoped CRM contact evidence and staff-operated WhatsApp inbox.
-- This migration records provider-neutral facts only. Provider credentials and
-- delivery workers remain deployment concerns and are not stored here.

CREATE TABLE public.crm_contact_methods (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  lead_id uuid REFERENCES public.leads(id) ON DELETE RESTRICT,
  client_id uuid REFERENCES public.clients(id) ON DELETE RESTRICT,
  kind text NOT NULL CHECK (kind IN ('email', 'phone', 'whatsapp')),
  normalized_value text NOT NULL CHECK (char_length(btrim(normalized_value)) BETWEEN 1 AND 320),
  display_value text NOT NULL CHECK (char_length(btrim(display_value)) BETWEEN 1 AND 320),
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  created_by_membership_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT crm_contact_method_creator_in_organization_fk
    FOREIGN KEY (organization_id, created_by_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT crm_contact_method_unique_value UNIQUE (organization_id, kind, normalized_value),
  CONSTRAINT crm_contact_method_idempotency_unique UNIQUE (organization_id, idempotency_key)
);

CREATE INDEX crm_contact_methods_lead_idx ON public.crm_contact_methods (organization_id, lead_id);
CREATE INDEX crm_contact_methods_client_idx ON public.crm_contact_methods (organization_id, client_id);

CREATE TABLE public.crm_consent_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  contact_method_id uuid NOT NULL REFERENCES public.crm_contact_methods(id) ON DELETE RESTRICT,
  consent_scope text NOT NULL CHECK (consent_scope ~ '^[a-z][a-z0-9_.-]{0,79}$'),
  status text NOT NULL CHECK (status IN ('granted', 'revoked', 'unknown')),
  source text NOT NULL CHECK (source ~ '^[a-z][a-z0-9_.-]{0,79}$'),
  evidence_reference text CHECK (evidence_reference IS NULL OR char_length(btrim(evidence_reference)) BETWEEN 1 AND 256),
  created_by_membership_id uuid NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT crm_consent_creator_in_organization_fk
    FOREIGN KEY (organization_id, created_by_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT
);

CREATE INDEX crm_consent_events_contact_idx ON public.crm_consent_events (organization_id, contact_method_id, occurred_at DESC);

CREATE TABLE public.whatsapp_channels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  provider text NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_.-]{0,79}$'),
  external_channel_id text NOT NULL CHECK (char_length(btrim(external_channel_id)) BETWEEN 1 AND 256),
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 160),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  kill_switch boolean NOT NULL DEFAULT false,
  created_by_membership_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT whatsapp_channel_creator_in_organization_fk
    FOREIGN KEY (organization_id, created_by_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT whatsapp_channel_organization_id_unique UNIQUE (organization_id, id),
  CONSTRAINT whatsapp_channel_external_unique UNIQUE (organization_id, provider, external_channel_id)
);

CREATE INDEX whatsapp_channels_organization_status_idx ON public.whatsapp_channels (organization_id, status, created_at DESC);

CREATE TABLE public.whatsapp_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  channel_id uuid NOT NULL REFERENCES public.whatsapp_channels(id) ON DELETE RESTRICT,
  contact_method_id uuid REFERENCES public.crm_contact_methods(id) ON DELETE RESTRICT,
  lead_id uuid REFERENCES public.leads(id) ON DELETE RESTRICT,
  client_id uuid REFERENCES public.clients(id) ON DELETE RESTRICT,
  external_conversation_key text NOT NULL CHECK (char_length(btrim(external_conversation_key)) BETWEEN 1 AND 256),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'pending', 'handoff', 'closed')),
  assigned_membership_id uuid,
  last_message_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT whatsapp_conversation_channel_in_organization_fk
    FOREIGN KEY (organization_id, channel_id)
    REFERENCES public.whatsapp_channels(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT whatsapp_conversation_assignee_in_organization_fk
    FOREIGN KEY (organization_id, assigned_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT whatsapp_conversation_external_unique UNIQUE (organization_id, channel_id, external_conversation_key),
  CONSTRAINT whatsapp_conversation_updated_at_trigger CHECK (updated_at IS NOT NULL)
);

CREATE INDEX whatsapp_conversations_queue_idx ON public.whatsapp_conversations (organization_id, status, last_message_at DESC NULLS LAST);
CREATE INDEX whatsapp_conversations_assignee_idx ON public.whatsapp_conversations (organization_id, assigned_membership_id, status);
CREATE TRIGGER whatsapp_conversations_set_updated_at
  BEFORE UPDATE ON public.whatsapp_conversations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.whatsapp_message_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  conversation_id uuid NOT NULL REFERENCES public.whatsapp_conversations(id) ON DELETE RESTRICT,
  event_key text NOT NULL CHECK (char_length(btrim(event_key)) BETWEEN 1 AND 320),
  direction text NOT NULL CHECK (direction IN ('inbound', 'outbound')),
  body_text text NOT NULL CHECK (char_length(btrim(body_text)) BETWEEN 1 AND 4096),
  delivery_status text NOT NULL CHECK (delivery_status IN ('received', 'queued', 'sent', 'delivered', 'failed')),
  created_by_membership_id uuid,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  idempotency_key text,
  CONSTRAINT whatsapp_message_creator_in_organization_fk
    FOREIGN KEY (organization_id, created_by_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT whatsapp_message_event_unique UNIQUE (organization_id, event_key),
  CONSTRAINT whatsapp_message_idempotency_unique UNIQUE (organization_id, idempotency_key)
);

CREATE INDEX whatsapp_message_events_conversation_idx ON public.whatsapp_message_events (organization_id, conversation_id, created_at ASC);

CREATE TABLE public.whatsapp_internal_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  conversation_id uuid NOT NULL REFERENCES public.whatsapp_conversations(id) ON DELETE RESTRICT,
  note_text text NOT NULL CHECK (char_length(btrim(note_text)) BETWEEN 1 AND 4096),
  created_by_membership_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT whatsapp_note_creator_in_organization_fk
    FOREIGN KEY (organization_id, created_by_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT
);

CREATE INDEX whatsapp_internal_notes_conversation_idx ON public.whatsapp_internal_notes (organization_id, conversation_id, created_at ASC);

ALTER TABLE public.crm_contact_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_consent_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_message_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_internal_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_contact_methods FORCE ROW LEVEL SECURITY;
ALTER TABLE public.crm_consent_events FORCE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_channels FORCE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_conversations FORCE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_message_events FORCE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_internal_notes FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.crm_contact_methods, public.crm_consent_events,
  public.whatsapp_channels, public.whatsapp_conversations,
  public.whatsapp_message_events, public.whatsapp_internal_notes FROM PUBLIC;

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
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
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

  SELECT * INTO v_existing
  FROM public.crm_contact_methods
  WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.kind = p_kind
      AND v_existing.normalized_value = btrim(p_normalized_value)
      AND v_existing.display_value = btrim(p_display_value)
      AND v_existing.lead_id IS NOT DISTINCT FROM p_lead_id
      AND v_existing.client_id IS NOT DISTINCT FROM p_client_id THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different contact method' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.crm_contact_methods (
    organization_id, lead_id, client_id, kind, normalized_value,
    display_value, idempotency_key, created_by_membership_id
  ) VALUES (
    p_organization_id, p_lead_id, p_client_id, p_kind, btrim(p_normalized_value),
    btrim(p_display_value), btrim(p_idempotency_key), v_actor
  ) RETURNING id INTO v_id;

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

CREATE OR REPLACE FUNCTION public.record_crm_consent(
  p_organization_id uuid,
  p_contact_method_id uuid,
  p_consent_scope text,
  p_status text,
  p_source text,
  p_evidence_reference text DEFAULT NULL,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'consent recording is not permitted' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.crm_contact_methods
    WHERE id = p_contact_method_id AND organization_id = p_organization_id
  ) THEN RAISE EXCEPTION 'contact method is invalid' USING ERRCODE = '23503'; END IF;
  IF p_consent_scope IS NULL OR p_consent_scope !~ '^[a-z][a-z0-9_.-]{0,79}$'
    OR p_status IS NULL OR p_status NOT IN ('granted', 'revoked', 'unknown')
    OR p_source IS NULL OR p_source !~ '^[a-z][a-z0-9_.-]{0,79}$' THEN
    RAISE EXCEPTION 'consent input is invalid' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.crm_consent_events (
    organization_id, contact_method_id, consent_scope, status, source,
    evidence_reference, created_by_membership_id
  ) VALUES (
    p_organization_id, p_contact_method_id, p_consent_scope, p_status, p_source,
    NULLIF(btrim(p_evidence_reference), ''), v_actor
  ) RETURNING id INTO v_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'crm.consent.recorded', 'crm_consent_event',
    v_id, 'success', p_request_id,
    jsonb_build_object('contact_method_id', p_contact_method_id, 'scope', p_consent_scope, 'status', p_status, 'source', p_source)
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_whatsapp_channel(
  p_organization_id uuid,
  p_provider text,
  p_external_channel_id text,
  p_display_name text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'channel creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_provider IS NULL OR p_provider !~ '^[a-z][a-z0-9_.-]{0,79}$'
    OR p_external_channel_id IS NULL OR char_length(btrim(p_external_channel_id)) NOT BETWEEN 1 AND 256
    OR p_display_name IS NULL OR char_length(btrim(p_display_name)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'channel input is invalid' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.whatsapp_channels (
    organization_id, provider, external_channel_id, display_name, created_by_membership_id
  ) VALUES (
    p_organization_id, p_provider, btrim(p_external_channel_id), btrim(p_display_name), v_actor
  ) RETURNING id INTO v_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'whatsapp.channel.created', 'whatsapp_channel',
    v_id, 'success', p_request_id, jsonb_build_object('provider', p_provider, 'display_name', p_display_name)
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_whatsapp_channels(p_organization_id uuid)
RETURNS TABLE (
  id uuid,
  provider text,
  external_channel_id text,
  display_name text,
  status text,
  kill_switch boolean,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_role text;
BEGIN
  SELECT membership.role INTO v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RAISE EXCEPTION 'channel read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT channel.id, channel.provider, channel.external_channel_id, channel.display_name,
         channel.status, channel.kill_switch, channel.created_at
  FROM public.whatsapp_channels AS channel
  WHERE channel.organization_id = p_organization_id
  ORDER BY channel.created_at DESC, channel.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_whatsapp_conversation(
  p_organization_id uuid,
  p_channel_id uuid,
  p_external_conversation_key text,
  p_contact_method_id uuid DEFAULT NULL,
  p_lead_id uuid DEFAULT NULL,
  p_client_id uuid DEFAULT NULL,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_existing public.whatsapp_conversations%ROWTYPE;
  v_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'conversation creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.whatsapp_channels
    WHERE id = p_channel_id AND organization_id = p_organization_id AND status = 'active' AND kill_switch = false
  ) THEN RAISE EXCEPTION 'channel is unavailable' USING ERRCODE = '42501'; END IF;
  IF p_external_conversation_key IS NULL OR char_length(btrim(p_external_conversation_key)) NOT BETWEEN 1 AND 256 THEN
    RAISE EXCEPTION 'conversation key is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_contact_method_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.crm_contact_methods WHERE id = p_contact_method_id AND organization_id = p_organization_id
  ) THEN RAISE EXCEPTION 'conversation contact is invalid' USING ERRCODE = '23503'; END IF;
  IF p_lead_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.leads WHERE id = p_lead_id AND organization_id = p_organization_id
  ) THEN RAISE EXCEPTION 'conversation lead is invalid' USING ERRCODE = '23503'; END IF;
  IF p_client_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.clients WHERE id = p_client_id AND organization_id = p_organization_id
  ) THEN RAISE EXCEPTION 'conversation client is invalid' USING ERRCODE = '23503'; END IF;

  SELECT * INTO v_existing
  FROM public.whatsapp_conversations
  WHERE organization_id = p_organization_id
    AND channel_id = p_channel_id
    AND external_conversation_key = btrim(p_external_conversation_key);
  IF FOUND THEN RETURN v_existing.id; END IF;

  INSERT INTO public.whatsapp_conversations (
    organization_id, channel_id, contact_method_id, lead_id, client_id, external_conversation_key
  ) VALUES (
    p_organization_id, p_channel_id, p_contact_method_id, p_lead_id, p_client_id, btrim(p_external_conversation_key)
  ) RETURNING id INTO v_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'whatsapp.conversation.created', 'whatsapp_conversation',
    v_id, 'success', p_request_id, jsonb_build_object('channel_id', p_channel_id, 'lead_id', p_lead_id, 'client_id', p_client_id)
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_whatsapp_conversations(p_organization_id uuid)
RETURNS TABLE (
  id uuid,
  channel_id uuid,
  channel_name text,
  contact_label text,
  status text,
  assigned_membership_id uuid,
  last_message_at timestamptz,
  last_message_preview text,
  last_message_direction text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_role text;
  v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RAISE EXCEPTION 'conversation read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT conversation.id,
         conversation.channel_id,
         channel.display_name,
         coalesce(contact.display_value, client_record.display_name, lead_record.title, 'جهة اتصال غير معروفة'),
         conversation.status,
         conversation.assigned_membership_id,
         latest.created_at,
         latest.body_text,
         latest.direction
  FROM public.whatsapp_conversations AS conversation
  JOIN public.whatsapp_channels AS channel
    ON channel.id = conversation.channel_id
   AND channel.organization_id = conversation.organization_id
  LEFT JOIN public.crm_contact_methods AS contact
    ON contact.id = conversation.contact_method_id
   AND contact.organization_id = conversation.organization_id
  LEFT JOIN public.clients AS client_record
    ON client_record.id = conversation.client_id
   AND client_record.organization_id = conversation.organization_id
  LEFT JOIN public.leads AS lead_record
    ON lead_record.id = conversation.lead_id
   AND lead_record.organization_id = conversation.organization_id
  LEFT JOIN LATERAL (
    SELECT message.created_at, message.body_text, message.direction
    FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = conversation.organization_id
      AND message.conversation_id = conversation.id
    ORDER BY message.created_at DESC, message.id DESC
    LIMIT 1
  ) AS latest ON true
  WHERE conversation.organization_id = p_organization_id
    AND (v_role IN ('owner', 'manager') OR conversation.assigned_membership_id IS NULL OR conversation.assigned_membership_id = v_actor)
  ORDER BY conversation.last_message_at DESC NULLS LAST, conversation.created_at DESC, conversation.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_whatsapp_messages(
  p_organization_id uuid,
  p_conversation_id uuid
)
RETURNS TABLE (
  id uuid,
  direction text,
  body_text text,
  delivery_status text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RAISE EXCEPTION 'message read is not permitted' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.whatsapp_conversations AS conversation
    WHERE conversation.id = p_conversation_id AND conversation.organization_id = p_organization_id
      AND (v_role IN ('owner', 'manager') OR conversation.assigned_membership_id IS NULL OR conversation.assigned_membership_id = v_actor)
  ) THEN RAISE EXCEPTION 'conversation is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY
  SELECT message.id, message.direction, message.body_text, message.delivery_status, message.created_at
  FROM public.whatsapp_message_events AS message
  WHERE message.organization_id = p_organization_id AND message.conversation_id = p_conversation_id
  ORDER BY message.created_at ASC, message.id ASC;
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
  IF v_actor IS NULL THEN RAISE EXCEPTION 'message creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_body_text IS NULL OR char_length(btrim(p_body_text)) NOT BETWEEN 1 AND 4096
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
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
  ) THEN RAISE EXCEPTION 'conversation is unavailable' USING ERRCODE = '42501'; END IF;

  SELECT * INTO v_existing
  FROM public.whatsapp_message_events
  WHERE organization_id = p_organization_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.body_text = btrim(p_body_text) AND v_existing.conversation_id = p_conversation_id THEN RETURN v_existing.id; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different message' USING ERRCODE = '23505';
  END IF;

  v_event_key := 'manual:' || public.gen_random_uuid()::text;
  INSERT INTO public.whatsapp_message_events (
    organization_id, conversation_id, event_key, direction, body_text,
    delivery_status, created_by_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, p_conversation_id, v_event_key, 'outbound', btrim(p_body_text),
    'queued', v_actor, btrim(p_idempotency_key)
  ) RETURNING id INTO v_id;

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
DECLARE v_actor uuid; v_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'note creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_note_text IS NULL OR char_length(btrim(p_note_text)) NOT BETWEEN 1 AND 4096 THEN
    RAISE EXCEPTION 'note input is invalid' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.whatsapp_conversations
    WHERE id = p_conversation_id AND organization_id = p_organization_id
  ) THEN RAISE EXCEPTION 'conversation is invalid' USING ERRCODE = '23503'; END IF;
  INSERT INTO public.whatsapp_internal_notes (
    organization_id, conversation_id, note_text, created_by_membership_id
  ) VALUES (p_organization_id, p_conversation_id, btrim(p_note_text), v_actor)
  RETURNING id INTO v_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'whatsapp.note.created', 'whatsapp_internal_note',
    v_id, 'success', p_request_id, jsonb_build_object('conversation_id', p_conversation_id)
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.assign_whatsapp_conversation(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_assigned_membership_id uuid,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_old uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'conversation assignment is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_assigned_membership_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.organization_memberships
    WHERE id = p_assigned_membership_id AND organization_id = p_organization_id AND status = 'active'
  ) THEN RAISE EXCEPTION 'conversation assignee is invalid' USING ERRCODE = '23503'; END IF;
  SELECT assigned_membership_id INTO v_old
  FROM public.whatsapp_conversations
  WHERE id = p_conversation_id AND organization_id = p_organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'conversation is invalid' USING ERRCODE = '23503'; END IF;
  UPDATE public.whatsapp_conversations
  SET assigned_membership_id = p_assigned_membership_id
  WHERE id = p_conversation_id AND organization_id = p_organization_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'whatsapp.conversation.assigned', 'whatsapp_conversation',
    p_conversation_id, 'success', p_request_id,
    jsonb_build_object('assigned_membership_id', v_old),
    jsonb_build_object('assigned_membership_id', p_assigned_membership_id)
  );
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.create_crm_contact_method(uuid, text, text, text, uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_crm_consent(uuid, uuid, text, text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_whatsapp_channel(uuid, text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_whatsapp_channels(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_whatsapp_conversation(uuid, uuid, text, uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_whatsapp_conversations(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_whatsapp_messages(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_whatsapp_message(uuid, uuid, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_whatsapp_internal_note(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assign_whatsapp_conversation(uuid, uuid, uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  public.create_crm_contact_method(uuid, text, text, text, uuid, uuid, text, uuid),
  public.record_crm_consent(uuid, uuid, text, text, text, text, uuid),
  public.create_whatsapp_channel(uuid, text, text, text, uuid),
  public.list_whatsapp_channels(uuid),
  public.create_whatsapp_conversation(uuid, uuid, text, uuid, uuid, uuid, uuid),
  public.list_whatsapp_conversations(uuid),
  public.list_whatsapp_messages(uuid, uuid),
  public.create_whatsapp_message(uuid, uuid, text, text, uuid),
  public.add_whatsapp_internal_note(uuid, uuid, text, uuid),
  public.assign_whatsapp_conversation(uuid, uuid, uuid, uuid)
TO authenticated;
