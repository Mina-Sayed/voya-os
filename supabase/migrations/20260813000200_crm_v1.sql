-- Voya OS: V1 CRM fields, append-only activities, follow-ups, and lead conversion.
-- Contact duplication is warning-only; this migration never auto-merges records.

CREATE OR REPLACE FUNCTION public.crm_normalize_phone(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT NULLIF(regexp_replace(coalesce(btrim(p_value), ''), '[^0-9]+', '', 'g'), '');
$$;

CREATE OR REPLACE FUNCTION public.crm_normalize_email(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT NULLIF(lower(btrim(p_value)), '');
$$;

ALTER TABLE public.leads
  ADD COLUMN IF NOT EXISTS name text,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS whatsapp text,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS normalized_phone text,
  ADD COLUMN IF NOT EXISTS normalized_email text,
  ADD COLUMN IF NOT EXISTS requested_area text,
  ADD COLUMN IF NOT EXISTS guests integer,
  ADD COLUMN IF NOT EXISTS bedrooms integer,
  ADD COLUMN IF NOT EXISTS budget_text text,
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS next_follow_up_at timestamptz,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS converted_client_id uuid;

UPDATE public.leads SET name = title WHERE name IS NULL;
UPDATE public.leads SET normalized_phone = public.crm_normalize_phone(phone) WHERE normalized_phone IS NULL AND phone IS NOT NULL;
UPDATE public.leads SET normalized_email = public.crm_normalize_email(email) WHERE normalized_email IS NULL AND email IS NOT NULL;
UPDATE public.leads SET status = 'won' WHERE status = 'converted';

ALTER TABLE public.leads
  DROP CONSTRAINT IF EXISTS leads_status_check,
  ADD CONSTRAINT leads_v1_status_check CHECK (status IN ('new', 'contacted', 'qualified', 'offered', 'won', 'lost')),
  ADD CONSTRAINT leads_v1_version_valid CHECK (version > 0),
  ADD CONSTRAINT leads_v1_guests_valid CHECK (guests IS NULL OR guests BETWEEN 1 AND 50),
  ADD CONSTRAINT leads_v1_bedrooms_valid CHECK (bedrooms IS NULL OR bedrooms BETWEEN 0 AND 100),
  ADD CONSTRAINT leads_v1_archived_consistent CHECK ((archived_at IS NULL) OR (status IN ('lost', 'won', 'new', 'contacted', 'qualified', 'offered'))),
  ADD CONSTRAINT leads_v1_name_valid CHECK (name IS NULL OR char_length(btrim(name)) BETWEEN 1 AND 160),
  ADD CONSTRAINT leads_v1_converted_client_tenant_fk FOREIGN KEY (organization_id, converted_client_id)
    REFERENCES public.clients (organization_id, id) ON DELETE RESTRICT;

ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS whatsapp text,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS normalized_phone text,
  ADD COLUMN IF NOT EXISTS normalized_email text,
  ADD COLUMN IF NOT EXISTS nationality text,
  ADD COLUMN IF NOT EXISTS preferred_language text,
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS source_lead_id uuid,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

UPDATE public.clients SET normalized_phone = public.crm_normalize_phone(phone) WHERE normalized_phone IS NULL AND phone IS NOT NULL;
UPDATE public.clients SET normalized_email = public.crm_normalize_email(email) WHERE normalized_email IS NULL AND email IS NOT NULL;

ALTER TABLE public.clients
  ADD CONSTRAINT clients_v1_source_lead_unique UNIQUE (organization_id, source_lead_id),
  ADD CONSTRAINT clients_v1_source_lead_tenant_fk FOREIGN KEY (organization_id, source_lead_id)
    REFERENCES public.leads (organization_id, id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS leads_v1_normalized_phone_idx ON public.leads (organization_id, normalized_phone) WHERE normalized_phone IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS leads_v1_normalized_email_idx ON public.leads (organization_id, normalized_email) WHERE normalized_email IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS clients_v1_normalized_phone_idx ON public.clients (organization_id, normalized_phone) WHERE normalized_phone IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS clients_v1_normalized_email_idx ON public.clients (organization_id, normalized_email) WHERE normalized_email IS NOT NULL AND archived_at IS NULL;

CREATE TABLE public.crm_v1_command_idempotency (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  command text NOT NULL CHECK (command IN ('lead.update', 'lead.archive', 'lead.activity.create', 'lead.follow_up.create', 'lead.follow_up.complete', 'lead.convert', 'client.update', 'client.archive')),
  resource_id uuid NOT NULL,
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  result_id uuid,
  result_version integer,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, command, idempotency_key)
);

CREATE TABLE public.crm_activities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  lead_id uuid NOT NULL,
  actor_membership_id uuid NOT NULL,
  activity_type text NOT NULL CHECK (activity_type IN ('call', 'whatsapp', 'email', 'note', 'status_change', 'property_offered', 'booking_created')),
  content text NOT NULL CHECK (char_length(btrim(content)) BETWEEN 1 AND 4000),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT crm_activity_lead_tenant_fk FOREIGN KEY (organization_id, lead_id) REFERENCES public.leads (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT crm_activity_actor_tenant_fk FOREIGN KEY (organization_id, actor_membership_id) REFERENCES public.organization_memberships (organization_id, id) ON DELETE RESTRICT
);

CREATE TABLE public.crm_follow_ups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  lead_id uuid NOT NULL,
  assigned_membership_id uuid,
  due_at timestamptz NOT NULL,
  note text NOT NULL CHECK (char_length(btrim(note)) BETWEEN 1 AND 2000),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'cancelled')),
  completed_at timestamptz,
  completed_by_membership_id uuid,
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT crm_follow_up_lead_tenant_fk FOREIGN KEY (organization_id, lead_id) REFERENCES public.leads (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT crm_follow_up_assignee_tenant_fk FOREIGN KEY (organization_id, assigned_membership_id) REFERENCES public.organization_memberships (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT crm_follow_up_completed_by_tenant_fk FOREIGN KEY (organization_id, completed_by_membership_id) REFERENCES public.organization_memberships (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT crm_follow_up_completion_consistent CHECK ((status = 'completed') = (completed_at IS NOT NULL AND completed_by_membership_id IS NOT NULL)),
  UNIQUE (organization_id, idempotency_key)
);

CREATE INDEX crm_activities_lead_created_idx ON public.crm_activities (organization_id, lead_id, created_at ASC);
CREATE INDEX crm_follow_ups_queue_idx ON public.crm_follow_ups (organization_id, status, due_at ASC);
CREATE INDEX crm_follow_ups_lead_idx ON public.crm_follow_ups (organization_id, lead_id, due_at ASC);
CREATE TRIGGER crm_follow_ups_set_updated_at BEFORE UPDATE ON public.crm_follow_ups FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER crm_activities_immutable BEFORE UPDATE OR DELETE ON public.crm_activities FOR EACH ROW EXECUTE FUNCTION public.reject_immutable_record();

ALTER TABLE public.crm_v1_command_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_v1_command_idempotency FORCE ROW LEVEL SECURITY;
ALTER TABLE public.crm_activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_activities FORCE ROW LEVEL SECURITY;
ALTER TABLE public.crm_follow_ups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_follow_ups FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.crm_v1_command_idempotency, public.crm_activities, public.crm_follow_ups FROM PUBLIC, authenticated;

-- Preserve the old command contract for existing callers while storing its
-- title as the V1 name. New UI flows use the V1 command below.
CREATE OR REPLACE FUNCTION public.create_lead(
  p_organization_id uuid, p_title text, p_source text, p_status text,
  p_requested_check_in date, p_requested_check_out date,
  p_assigned_membership_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_actor uuid;
  v_existing public.leads%ROWTYPE;
  v_id uuid;
  v_status text := CASE WHEN p_status = 'converted' THEN 'won' ELSE p_status END;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'lead creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_title IS NULL OR char_length(btrim(p_title)) NOT BETWEEN 1 AND 160
    OR p_source IS NULL OR p_source !~ '^[a-z][a-z0-9_-]{0,63}$'
    OR v_status NOT IN ('new', 'contacted', 'qualified', 'offered', 'won', 'lost')
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0
    OR ((p_requested_check_in IS NULL) <> (p_requested_check_out IS NULL))
    OR (p_requested_check_in IS NOT NULL AND p_requested_check_in >= p_requested_check_out) THEN
    RAISE EXCEPTION 'lead input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT lead_record.* INTO v_existing FROM public.leads AS lead_record
  WHERE lead_record.organization_id = p_organization_id AND lead_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.title = btrim(p_title) AND v_existing.source = p_source AND v_existing.status = v_status
      AND v_existing.requested_check_in IS NOT DISTINCT FROM p_requested_check_in
      AND v_existing.requested_check_out IS NOT DISTINCT FROM p_requested_check_out
      AND v_existing.assigned_membership_id IS NOT DISTINCT FROM p_assigned_membership_id THEN RETURN v_existing.id; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different lead' USING ERRCODE = '23505';
  END IF;
  IF p_assigned_membership_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.id = p_assigned_membership_id AND membership.organization_id = p_organization_id AND membership.status = 'active'
  ) THEN RAISE EXCEPTION 'lead assignee is invalid' USING ERRCODE = '23503'; END IF;
  INSERT INTO public.leads (organization_id, title, name, source, status, requested_check_in, requested_check_out, assigned_membership_id, idempotency_key)
  VALUES (p_organization_id, btrim(p_title), btrim(p_title), p_source, v_status, p_requested_check_in, p_requested_check_out, p_assigned_membership_id, p_idempotency_key)
  RETURNING id INTO v_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'lead.created', 'lead', v_id, 'success', p_request_id, jsonb_build_object('name', btrim(p_title), 'source', p_source, 'status', v_status));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'lead.created', 1, 'lead:' || v_id::text, jsonb_build_object('lead_id', v_id));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_lead_v1(
  p_organization_id uuid, p_name text, p_phone text, p_whatsapp text, p_email text,
  p_source text, p_status text, p_assigned_membership_id uuid, p_requested_area text,
  p_check_in date, p_check_out date, p_guests integer, p_bedrooms integer,
  p_budget_text text, p_notes text, p_next_follow_up_at timestamptz,
  p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_actor uuid;
  v_existing public.leads%ROWTYPE;
  v_id uuid;
  v_phone text := public.crm_normalize_phone(p_phone);
  v_whatsapp text := public.crm_normalize_phone(p_whatsapp);
  v_email text := public.crm_normalize_email(p_email);
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'lead creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_name IS NULL OR char_length(btrim(p_name)) NOT BETWEEN 1 AND 160
    OR (v_phone IS NULL AND v_whatsapp IS NULL AND v_email IS NULL)
    OR p_source IS NULL OR p_source !~ '^[a-z][a-z0-9_-]{0,63}$'
    OR p_status NOT IN ('new', 'contacted', 'qualified', 'offered', 'won', 'lost')
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0
    OR ((p_check_in IS NULL) <> (p_check_out IS NULL))
    OR (p_check_in IS NOT NULL AND p_check_in >= p_check_out)
    OR (p_guests IS NOT NULL AND p_guests NOT BETWEEN 1 AND 50)
    OR (p_bedrooms IS NOT NULL AND p_bedrooms NOT BETWEEN 0 AND 100) THEN
    RAISE EXCEPTION 'lead V1 input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_assigned_membership_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.id = p_assigned_membership_id AND membership.organization_id = p_organization_id AND membership.status = 'active'
  ) THEN RAISE EXCEPTION 'lead assignee is invalid' USING ERRCODE = '23503'; END IF;
  SELECT lead_record.* INTO v_existing FROM public.leads AS lead_record
  WHERE lead_record.organization_id = p_organization_id AND lead_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.name = btrim(p_name) AND v_existing.normalized_phone IS NOT DISTINCT FROM v_phone
      AND v_existing.whatsapp IS NOT DISTINCT FROM NULLIF(btrim(p_whatsapp), '')
      AND v_existing.normalized_email IS NOT DISTINCT FROM v_email AND v_existing.source = p_source
      AND v_existing.requested_area IS NOT DISTINCT FROM NULLIF(btrim(p_requested_area), '')
      AND v_existing.requested_check_in IS NOT DISTINCT FROM p_check_in AND v_existing.requested_check_out IS NOT DISTINCT FROM p_check_out
      AND v_existing.guests IS NOT DISTINCT FROM p_guests AND v_existing.bedrooms IS NOT DISTINCT FROM p_bedrooms
      AND v_existing.budget_text IS NOT DISTINCT FROM NULLIF(btrim(p_budget_text), '')
      AND v_existing.notes IS NOT DISTINCT FROM NULLIF(btrim(p_notes), '')
      AND v_existing.next_follow_up_at IS NOT DISTINCT FROM p_next_follow_up_at
      AND v_existing.assigned_membership_id IS NOT DISTINCT FROM p_assigned_membership_id THEN RETURN v_existing.id; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different lead' USING ERRCODE = '23505';
  END IF;
  INSERT INTO public.leads (
    organization_id, title, name, phone, whatsapp, email, normalized_phone, normalized_email,
    source, status, requested_check_in, requested_check_out, assigned_membership_id,
    requested_area, guests, bedrooms, budget_text, notes, next_follow_up_at, idempotency_key
  ) VALUES (
    p_organization_id, btrim(p_name), btrim(p_name), NULLIF(btrim(p_phone), ''), NULLIF(btrim(p_whatsapp), ''), NULLIF(lower(btrim(p_email)), ''),
    v_phone, v_email, p_source, p_status, p_check_in, p_check_out, p_assigned_membership_id,
    NULLIF(btrim(p_requested_area), ''), p_guests, p_bedrooms, NULLIF(btrim(p_budget_text), ''), NULLIF(btrim(p_notes), ''), p_next_follow_up_at, p_idempotency_key
  ) RETURNING id INTO v_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'lead.created', 'lead', v_id, 'success', p_request_id, jsonb_build_object('name', btrim(p_name), 'source', p_source, 'status', p_status));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'lead.created', 1, 'lead-v1:' || v_id::text, jsonb_build_object('lead_id', v_id));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_leads_v1(p_organization_id uuid)
RETURNS TABLE (
  id uuid, name text, phone text, whatsapp text, email text, normalized_phone text, normalized_email text,
  source text, status text, assigned_membership_id uuid, requested_area text, requested_check_in date,
  requested_check_out date, guests integer, bedrooms integer, budget_text text, notes text,
  next_follow_up_at timestamptz, version integer, converted_client_id uuid, created_at timestamptz,
  updated_at timestamptz, archived_at timestamptz, duplicate_warning boolean
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_role text; v_member uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_member FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'viewer') THEN RAISE EXCEPTION 'lead read is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY SELECT lead_record.id, COALESCE(lead_record.name, lead_record.title), lead_record.phone, lead_record.whatsapp, lead_record.email,
    lead_record.normalized_phone, lead_record.normalized_email, lead_record.source, lead_record.status,
    lead_record.assigned_membership_id, lead_record.requested_area, lead_record.requested_check_in, lead_record.requested_check_out,
    lead_record.guests, lead_record.bedrooms, lead_record.budget_text, lead_record.notes, lead_record.next_follow_up_at,
    lead_record.version, lead_record.converted_client_id, lead_record.created_at, lead_record.updated_at, lead_record.archived_at,
    EXISTS (
      SELECT 1 FROM public.leads AS duplicate
      WHERE duplicate.organization_id = lead_record.organization_id AND duplicate.id <> lead_record.id AND duplicate.archived_at IS NULL
        AND ((lead_record.normalized_phone IS NOT NULL AND duplicate.normalized_phone = lead_record.normalized_phone)
          OR (lead_record.normalized_email IS NOT NULL AND duplicate.normalized_email = lead_record.normalized_email))
    )
  FROM public.leads AS lead_record
  WHERE lead_record.organization_id = p_organization_id
    AND (v_role IN ('owner', 'manager', 'operations', 'viewer') OR lead_record.assigned_membership_id IS NULL OR lead_record.assigned_membership_id = v_member)
  ORDER BY lead_record.created_at DESC, lead_record.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_lead_v1(
  p_organization_id uuid, p_lead_id uuid, p_name text, p_phone text, p_whatsapp text, p_email text,
  p_source text, p_status text, p_assigned_membership_id uuid, p_requested_area text,
  p_check_in date, p_check_out date, p_guests integer, p_bedrooms integer, p_budget_text text,
  p_notes text, p_next_follow_up_at timestamptz, p_expected_version integer,
  p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_actor uuid; v_before public.leads%ROWTYPE; v_new_version integer;
  v_existing public.crm_v1_command_idempotency%ROWTYPE;
  v_phone text := public.crm_normalize_phone(p_phone); v_whatsapp text := public.crm_normalize_phone(p_whatsapp); v_email text := public.crm_normalize_email(p_email);
BEGIN
  IF p_lead_id IS NULL OR p_name IS NULL OR char_length(btrim(p_name)) NOT BETWEEN 1 AND 160
    OR (v_phone IS NULL AND v_whatsapp IS NULL AND v_email IS NULL) OR p_source IS NULL OR p_source !~ '^[a-z][a-z0-9_-]{0,63}$'
    OR p_status NOT IN ('new', 'contacted', 'qualified', 'offered', 'won', 'lost') OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 OR ((p_check_in IS NULL) <> (p_check_out IS NULL))
    OR (p_check_in IS NOT NULL AND p_check_in >= p_check_out) OR (p_guests IS NOT NULL AND p_guests NOT BETWEEN 1 AND 50)
    OR (p_bedrooms IS NOT NULL AND p_bedrooms NOT BETWEEN 0 AND 100) THEN
    RAISE EXCEPTION 'lead update input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'lead update is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_assigned_membership_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.organization_memberships AS membership WHERE membership.id = p_assigned_membership_id AND membership.organization_id = p_organization_id AND membership.status = 'active') THEN RAISE EXCEPTION 'lead assignee is invalid' USING ERRCODE = '23503'; END IF;
  SELECT command_record.* INTO v_existing FROM public.crm_v1_command_idempotency AS command_record WHERE command_record.organization_id = p_organization_id AND command_record.command = 'lead.update' AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN IF v_existing.resource_id = p_lead_id THEN RETURN true; END IF; RAISE EXCEPTION 'idempotency key belongs to a different lead update' USING ERRCODE = '23505'; END IF;
  SELECT lead_record.* INTO v_before FROM public.leads AS lead_record WHERE lead_record.organization_id = p_organization_id AND lead_record.id = p_lead_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'lead was not found' USING ERRCODE = '23503'; END IF;
  UPDATE public.leads SET title = btrim(p_name), name = btrim(p_name), phone = NULLIF(btrim(p_phone), ''), whatsapp = NULLIF(btrim(p_whatsapp), ''), email = NULLIF(lower(btrim(p_email)), ''), normalized_phone = v_phone, normalized_email = v_email, source = p_source, status = p_status, assigned_membership_id = p_assigned_membership_id, requested_area = NULLIF(btrim(p_requested_area), ''), requested_check_in = p_check_in, requested_check_out = p_check_out, guests = p_guests, bedrooms = p_bedrooms, budget_text = NULLIF(btrim(p_budget_text), ''), notes = NULLIF(btrim(p_notes), ''), next_follow_up_at = p_next_follow_up_at, archived_at = NULL, version = version + 1 WHERE organization_id = p_organization_id AND id = p_lead_id AND version = p_expected_version RETURNING version INTO v_new_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'lead version is stale' USING ERRCODE = '40001'; END IF;
  INSERT INTO public.crm_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_version) VALUES (p_organization_id, 'lead.update', p_lead_id, p_idempotency_key, v_new_version);
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, before_delta, after_delta) VALUES (p_organization_id, 'user', v_actor, 'lead.updated', 'lead', p_lead_id, 'success', p_request_id, jsonb_build_object('version', v_before.version, 'status', v_before.status), jsonb_build_object('version', v_new_version, 'status', p_status));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'lead.updated', 1, 'lead-v1-update:' || p_lead_id::text || ':' || p_idempotency_key, jsonb_build_object('lead_id', p_lead_id, 'version', v_new_version));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_lead_v1(p_organization_id uuid, p_lead_id uuid, p_reason text, p_expected_version integer, p_idempotency_key text, p_request_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid; v_new_version integer; v_existing public.crm_v1_command_idempotency%ROWTYPE;
BEGIN
  IF p_lead_id IS NULL OR p_reason IS NULL OR char_length(btrim(p_reason)) = 0 OR p_expected_version IS NULL OR p_expected_version < 1 OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN RAISE EXCEPTION 'lead archive input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'lead archive is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT command_record.* INTO v_existing FROM public.crm_v1_command_idempotency AS command_record WHERE command_record.organization_id = p_organization_id AND command_record.command = 'lead.archive' AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN IF v_existing.resource_id = p_lead_id THEN RETURN true; END IF; RAISE EXCEPTION 'idempotency key belongs to a different lead archive' USING ERRCODE = '23505'; END IF;
  UPDATE public.leads SET archived_at = timezone('utc', now()), version = version + 1 WHERE organization_id = p_organization_id AND id = p_lead_id AND version = p_expected_version AND archived_at IS NULL RETURNING version INTO v_new_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'lead was not found or version is stale' USING ERRCODE = '40001'; END IF;
  INSERT INTO public.crm_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_version) VALUES (p_organization_id, 'lead.archive', p_lead_id, p_idempotency_key, v_new_version);
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta) VALUES (p_organization_id, 'user', v_actor, 'lead.archived', 'lead', p_lead_id, 'success', p_request_id, 'user_requested', jsonb_build_object('version', v_new_version, 'reason', btrim(p_reason)));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'lead.archived', 1, 'lead-v1-archive:' || p_lead_id::text || ':' || p_idempotency_key, jsonb_build_object('lead_id', p_lead_id, 'version', v_new_version));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_lead_activity_v1(p_organization_id uuid, p_lead_id uuid, p_activity_type text, p_content text, p_idempotency_key text, p_request_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid; v_id uuid; v_existing public.crm_v1_command_idempotency%ROWTYPE;
BEGIN
  IF p_lead_id IS NULL OR p_activity_type NOT IN ('call', 'whatsapp', 'email', 'note', 'status_change', 'property_offered', 'booking_created') OR p_content IS NULL OR char_length(btrim(p_content)) NOT BETWEEN 1 AND 4000 OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN RAISE EXCEPTION 'lead activity input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'lead activity is not permitted' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.leads AS lead_record WHERE lead_record.organization_id = p_organization_id AND lead_record.id = p_lead_id) THEN RAISE EXCEPTION 'lead was not found' USING ERRCODE = '23503'; END IF;
  SELECT command_record.* INTO v_existing FROM public.crm_v1_command_idempotency AS command_record WHERE command_record.organization_id = p_organization_id AND command_record.command = 'lead.activity.create' AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN IF v_existing.resource_id = p_lead_id THEN RETURN v_existing.result_id; END IF; RAISE EXCEPTION 'idempotency key belongs to a different lead activity' USING ERRCODE = '23505'; END IF;
  INSERT INTO public.crm_activities (organization_id, lead_id, actor_membership_id, activity_type, content) VALUES (p_organization_id, p_lead_id, v_actor, p_activity_type, btrim(p_content)) RETURNING id INTO v_id;
  INSERT INTO public.crm_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_id) VALUES (p_organization_id, 'lead.activity.create', p_lead_id, p_idempotency_key, v_id);
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta) VALUES (p_organization_id, 'user', v_actor, 'lead.activity.created', 'lead_activity', v_id, 'success', p_request_id, jsonb_build_object('lead_id', p_lead_id, 'activity_type', p_activity_type));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_lead_activities_v1(p_organization_id uuid, p_lead_id uuid)
RETURNS TABLE (id uuid, lead_id uuid, actor_membership_id uuid, activity_type text, content text, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations', 'viewer')) THEN RAISE EXCEPTION 'lead activity read is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY SELECT activity.id, activity.lead_id, activity.actor_membership_id, activity.activity_type, activity.content, activity.created_at FROM public.crm_activities AS activity WHERE activity.organization_id = p_organization_id AND activity.lead_id = p_lead_id ORDER BY activity.created_at ASC, activity.id ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_lead_follow_up_v1(p_organization_id uuid, p_lead_id uuid, p_due_at timestamptz, p_note text, p_assigned_membership_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid; v_id uuid; v_existing public.crm_follow_ups%ROWTYPE;
BEGIN
  IF p_lead_id IS NULL OR p_due_at IS NULL OR p_note IS NULL OR char_length(btrim(p_note)) NOT BETWEEN 1 AND 2000 OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN RAISE EXCEPTION 'lead follow-up input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'lead follow-up is not permitted' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.leads AS lead_record WHERE lead_record.organization_id = p_organization_id AND lead_record.id = p_lead_id AND lead_record.archived_at IS NULL) THEN RAISE EXCEPTION 'lead was not found' USING ERRCODE = '23503'; END IF;
  IF p_assigned_membership_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.organization_memberships AS membership WHERE membership.id = p_assigned_membership_id AND membership.organization_id = p_organization_id AND membership.status = 'active') THEN RAISE EXCEPTION 'follow-up assignee is invalid' USING ERRCODE = '23503'; END IF;
  SELECT follow_up.* INTO v_existing FROM public.crm_follow_ups AS follow_up WHERE follow_up.organization_id = p_organization_id AND follow_up.idempotency_key = p_idempotency_key;
  IF FOUND THEN IF v_existing.lead_id = p_lead_id AND v_existing.due_at = p_due_at THEN RETURN v_existing.id; END IF; RAISE EXCEPTION 'idempotency key belongs to a different follow-up' USING ERRCODE = '23505'; END IF;
  INSERT INTO public.crm_follow_ups (organization_id, lead_id, assigned_membership_id, due_at, note, idempotency_key) VALUES (p_organization_id, p_lead_id, p_assigned_membership_id, p_due_at, btrim(p_note), p_idempotency_key) RETURNING id INTO v_id;
  UPDATE public.leads SET next_follow_up_at = CASE WHEN next_follow_up_at IS NULL OR p_due_at < next_follow_up_at THEN p_due_at ELSE next_follow_up_at END, version = version + 1 WHERE organization_id = p_organization_id AND id = p_lead_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta) VALUES (p_organization_id, 'user', v_actor, 'lead.follow_up.created', 'lead_follow_up', v_id, 'success', p_request_id, jsonb_build_object('lead_id', p_lead_id, 'due_at', p_due_at));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'lead.follow_up.created', 1, 'lead-follow-up-v1:' || v_id::text, jsonb_build_object('follow_up_id', v_id, 'lead_id', p_lead_id));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_lead_follow_ups_v1(p_organization_id uuid, p_lead_id uuid)
RETURNS TABLE (id uuid, lead_id uuid, assigned_membership_id uuid, due_at timestamptz, note text, status text, completed_at timestamptz, completed_by_membership_id uuid, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations', 'viewer')) THEN RAISE EXCEPTION 'lead follow-up read is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY SELECT follow_up.id, follow_up.lead_id, follow_up.assigned_membership_id, follow_up.due_at, follow_up.note, follow_up.status, follow_up.completed_at, follow_up.completed_by_membership_id, follow_up.created_at FROM public.crm_follow_ups AS follow_up WHERE follow_up.organization_id = p_organization_id AND follow_up.lead_id = p_lead_id ORDER BY follow_up.due_at ASC, follow_up.id ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_lead_follow_up_v1(p_organization_id uuid, p_follow_up_id uuid, p_note text, p_idempotency_key text, p_request_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid; v_lead_id uuid; v_existing public.crm_v1_command_idempotency%ROWTYPE; v_current_note text;
BEGIN
  IF p_follow_up_id IS NULL OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN RAISE EXCEPTION 'follow-up completion input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'follow-up completion is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT command_record.* INTO v_existing FROM public.crm_v1_command_idempotency AS command_record WHERE command_record.organization_id = p_organization_id AND command_record.command = 'lead.follow_up.complete' AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN IF v_existing.resource_id = p_follow_up_id THEN RETURN true; END IF; RAISE EXCEPTION 'idempotency key belongs to a different follow-up completion' USING ERRCODE = '23505'; END IF;
  SELECT follow_up.note INTO v_current_note FROM public.crm_follow_ups AS follow_up WHERE follow_up.organization_id = p_organization_id AND follow_up.id = p_follow_up_id AND follow_up.status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'pending follow-up was not found' USING ERRCODE = '40001'; END IF;
  IF p_note IS NOT NULL AND char_length(btrim(p_note)) > 0 AND char_length(v_current_note) + 1 + char_length(btrim(p_note)) > 2000 THEN RAISE EXCEPTION 'follow-up completion note is too long' USING ERRCODE = '22001'; END IF;
  UPDATE public.crm_follow_ups SET status = 'completed', completed_at = timezone('utc', now()), completed_by_membership_id = v_actor, note = CASE WHEN p_note IS NULL OR char_length(btrim(p_note)) = 0 THEN note ELSE note || E'\n' || btrim(p_note) END WHERE organization_id = p_organization_id AND id = p_follow_up_id AND status = 'pending' RETURNING lead_id INTO v_lead_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'pending follow-up was not found' USING ERRCODE = '40001'; END IF;
  INSERT INTO public.crm_v1_command_idempotency (organization_id, command, resource_id, idempotency_key) VALUES (p_organization_id, 'lead.follow_up.complete', p_follow_up_id, p_idempotency_key);
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta) VALUES (p_organization_id, 'user', v_actor, 'lead.follow_up.completed', 'lead_follow_up', p_follow_up_id, 'success', p_request_id, jsonb_build_object('lead_id', v_lead_id));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'lead.follow_up.completed', 1, 'lead-follow-up-v1-complete:' || p_follow_up_id::text || ':' || p_idempotency_key, jsonb_build_object('follow_up_id', p_follow_up_id, 'lead_id', v_lead_id));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_client_v1(
  p_organization_id uuid, p_display_name text, p_phone text, p_whatsapp text, p_email text,
  p_nationality text, p_preferred_language text, p_notes text, p_source_lead_id uuid,
  p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid; v_id uuid; v_existing public.clients%ROWTYPE; v_phone text := public.crm_normalize_phone(p_phone); v_email text := public.crm_normalize_email(p_email);
BEGIN
  IF p_display_name IS NULL OR char_length(btrim(p_display_name)) NOT BETWEEN 1 AND 160 OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN RAISE EXCEPTION 'client V1 input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'client creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_source_lead_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.leads AS lead_record WHERE lead_record.organization_id = p_organization_id AND lead_record.id = p_source_lead_id) THEN RAISE EXCEPTION 'source lead is invalid' USING ERRCODE = '23503'; END IF;
  SELECT client_record.* INTO v_existing FROM public.clients AS client_record WHERE client_record.organization_id = p_organization_id AND client_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN IF v_existing.display_name = btrim(p_display_name) AND v_existing.normalized_phone IS NOT DISTINCT FROM v_phone AND v_existing.normalized_email IS NOT DISTINCT FROM v_email THEN RETURN v_existing.id; END IF; RAISE EXCEPTION 'idempotency key belongs to a different client' USING ERRCODE = '23505'; END IF;
  INSERT INTO public.clients (organization_id, display_name, phone, whatsapp, email, normalized_phone, normalized_email, nationality, preferred_language, notes, source_lead_id, idempotency_key)
  VALUES (p_organization_id, btrim(p_display_name), NULLIF(btrim(p_phone), ''), NULLIF(btrim(p_whatsapp), ''), NULLIF(lower(btrim(p_email)), ''), v_phone, v_email, NULLIF(btrim(p_nationality), ''), NULLIF(btrim(p_preferred_language), ''), NULLIF(btrim(p_notes), ''), p_source_lead_id, p_idempotency_key) RETURNING id INTO v_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta) VALUES (p_organization_id, 'user', v_actor, 'client.created', 'client', v_id, 'success', p_request_id, jsonb_build_object('display_name', btrim(p_display_name), 'source_lead_id', p_source_lead_id));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'client.created', 1, 'client-v1:' || v_id::text, jsonb_build_object('client_id', v_id, 'source_lead_id', p_source_lead_id));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_clients_v1(p_organization_id uuid)
RETURNS TABLE (id uuid, display_name text, phone text, whatsapp text, email text, normalized_phone text, normalized_email text, nationality text, preferred_language text, notes text, source_lead_id uuid, version integer, created_at timestamptz, updated_at timestamptz, archived_at timestamptz, duplicate_warning boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations', 'accountant', 'viewer')) THEN RAISE EXCEPTION 'client read is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY SELECT client_record.id, client_record.display_name, client_record.phone, client_record.whatsapp, client_record.email, client_record.normalized_phone, client_record.normalized_email, client_record.nationality, client_record.preferred_language, client_record.notes, client_record.source_lead_id, client_record.version, client_record.created_at, client_record.updated_at, client_record.archived_at,
    EXISTS (SELECT 1 FROM public.clients AS duplicate WHERE duplicate.organization_id = client_record.organization_id AND duplicate.id <> client_record.id AND duplicate.archived_at IS NULL AND ((client_record.normalized_phone IS NOT NULL AND duplicate.normalized_phone = client_record.normalized_phone) OR (client_record.normalized_email IS NOT NULL AND duplicate.normalized_email = client_record.normalized_email)))
  FROM public.clients AS client_record WHERE client_record.organization_id = p_organization_id ORDER BY client_record.created_at DESC, client_record.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_client_v1(
  p_organization_id uuid, p_client_id uuid, p_display_name text, p_phone text, p_whatsapp text, p_email text,
  p_nationality text, p_preferred_language text, p_notes text, p_expected_version integer,
  p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid; v_before public.clients%ROWTYPE; v_new_version integer; v_existing public.crm_v1_command_idempotency%ROWTYPE; v_phone text := public.crm_normalize_phone(p_phone); v_email text := public.crm_normalize_email(p_email);
BEGIN
  IF p_client_id IS NULL OR p_display_name IS NULL OR char_length(btrim(p_display_name)) NOT BETWEEN 1 AND 160 OR p_expected_version IS NULL OR p_expected_version < 1 OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN RAISE EXCEPTION 'client update input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'client update is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT command_record.* INTO v_existing FROM public.crm_v1_command_idempotency AS command_record WHERE command_record.organization_id = p_organization_id AND command_record.command = 'client.update' AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN IF v_existing.resource_id = p_client_id THEN RETURN true; END IF; RAISE EXCEPTION 'idempotency key belongs to a different client update' USING ERRCODE = '23505'; END IF;
  SELECT client_record.* INTO v_before FROM public.clients AS client_record WHERE client_record.organization_id = p_organization_id AND client_record.id = p_client_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'client was not found' USING ERRCODE = '23503'; END IF;
  UPDATE public.clients SET display_name = btrim(p_display_name), phone = NULLIF(btrim(p_phone), ''), whatsapp = NULLIF(btrim(p_whatsapp), ''), email = NULLIF(lower(btrim(p_email)), ''), normalized_phone = v_phone, normalized_email = v_email, nationality = NULLIF(btrim(p_nationality), ''), preferred_language = NULLIF(btrim(p_preferred_language), ''), notes = NULLIF(btrim(p_notes), ''), archived_at = NULL, version = version + 1 WHERE organization_id = p_organization_id AND id = p_client_id AND version = p_expected_version RETURNING version INTO v_new_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'client version is stale' USING ERRCODE = '40001'; END IF;
  INSERT INTO public.crm_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_version) VALUES (p_organization_id, 'client.update', p_client_id, p_idempotency_key, v_new_version);
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, before_delta, after_delta) VALUES (p_organization_id, 'user', v_actor, 'client.updated', 'client', p_client_id, 'success', p_request_id, jsonb_build_object('version', v_before.version), jsonb_build_object('version', v_new_version));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_client_v1(p_organization_id uuid, p_client_id uuid, p_reason text, p_expected_version integer, p_idempotency_key text, p_request_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid; v_new_version integer; v_existing public.crm_v1_command_idempotency%ROWTYPE;
BEGIN
  IF p_client_id IS NULL OR p_reason IS NULL OR char_length(btrim(p_reason)) = 0 OR p_expected_version IS NULL OR p_expected_version < 1 OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN RAISE EXCEPTION 'client archive input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'client archive is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT command_record.* INTO v_existing FROM public.crm_v1_command_idempotency AS command_record WHERE command_record.organization_id = p_organization_id AND command_record.command = 'client.archive' AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN IF v_existing.resource_id = p_client_id THEN RETURN true; END IF; RAISE EXCEPTION 'idempotency key belongs to a different client archive' USING ERRCODE = '23505'; END IF;
  UPDATE public.clients SET archived_at = timezone('utc', now()), version = version + 1 WHERE organization_id = p_organization_id AND id = p_client_id AND version = p_expected_version AND archived_at IS NULL RETURNING version INTO v_new_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'client was not found or version is stale' USING ERRCODE = '40001'; END IF;
  INSERT INTO public.crm_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_version) VALUES (p_organization_id, 'client.archive', p_client_id, p_idempotency_key, v_new_version);
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta) VALUES (p_organization_id, 'user', v_actor, 'client.archived', 'client', p_client_id, 'success', p_request_id, 'user_requested', jsonb_build_object('version', v_new_version, 'reason', btrim(p_reason)));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.convert_lead_to_client_v1(p_organization_id uuid, p_lead_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid; v_lead public.leads%ROWTYPE; v_client_id uuid; v_existing public.crm_v1_command_idempotency%ROWTYPE;
BEGIN
  IF p_lead_id IS NULL OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN RAISE EXCEPTION 'lead conversion input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'lead conversion is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT command_record.* INTO v_existing FROM public.crm_v1_command_idempotency AS command_record WHERE command_record.organization_id = p_organization_id AND command_record.command = 'lead.convert' AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN IF v_existing.resource_id = p_lead_id THEN RETURN v_existing.result_id; END IF; RAISE EXCEPTION 'idempotency key belongs to a different lead conversion' USING ERRCODE = '23505'; END IF;
  SELECT lead_record.* INTO v_lead FROM public.leads AS lead_record WHERE lead_record.organization_id = p_organization_id AND lead_record.id = p_lead_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'lead was not found' USING ERRCODE = '23503'; END IF;
  IF v_lead.converted_client_id IS NOT NULL THEN
    INSERT INTO public.crm_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_id) VALUES (p_organization_id, 'lead.convert', p_lead_id, p_idempotency_key, v_lead.converted_client_id);
    RETURN v_lead.converted_client_id;
  END IF;
  IF v_lead.status = 'lost' OR v_lead.archived_at IS NOT NULL THEN RAISE EXCEPTION 'lost or archived lead cannot be converted' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.clients (organization_id, display_name, phone, whatsapp, email, normalized_phone, normalized_email, notes, source_lead_id, idempotency_key)
  VALUES (p_organization_id, COALESCE(v_lead.name, v_lead.title), v_lead.phone, v_lead.whatsapp, v_lead.email, v_lead.normalized_phone, v_lead.normalized_email, v_lead.notes, p_lead_id, 'lead-conversion:' || p_lead_id::text)
  ON CONFLICT (organization_id, source_lead_id) DO UPDATE SET display_name = EXCLUDED.display_name
  RETURNING id INTO v_client_id;
  UPDATE public.leads SET status = 'won', converted_client_id = v_client_id, version = version + 1 WHERE organization_id = p_organization_id AND id = p_lead_id;
  INSERT INTO public.crm_activities (organization_id, lead_id, actor_membership_id, activity_type, content) VALUES (p_organization_id, p_lead_id, v_actor, 'status_change', 'تم تحويل الطلب إلى عميل.');
  INSERT INTO public.crm_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_id) VALUES (p_organization_id, 'lead.convert', p_lead_id, p_idempotency_key, v_client_id);
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta) VALUES (p_organization_id, 'user', v_actor, 'lead.converted', 'lead', p_lead_id, 'success', p_request_id, jsonb_build_object('client_id', v_client_id, 'status', 'won'));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'lead.converted', 1, 'lead-converted-v1:' || p_lead_id::text, jsonb_build_object('lead_id', p_lead_id, 'client_id', v_client_id));
  RETURN v_client_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_lead_v1(uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_leads_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_lead_v1(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.archive_lead_v1(uuid,uuid,text,integer,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_lead_activity_v1(uuid,uuid,text,text,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_lead_activities_v1(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_lead_follow_up_v1(uuid,uuid,timestamptz,text,uuid,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_lead_follow_ups_v1(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.complete_lead_follow_up_v1(uuid,uuid,text,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_client_v1(uuid,text,text,text,text,text,text,text,uuid,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_clients_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_client_v1(uuid,uuid,text,text,text,text,text,text,text,integer,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.archive_client_v1(uuid,uuid,text,integer,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.convert_lead_to_client_v1(uuid,uuid,text,uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_lead_v1(uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_leads_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_lead_v1(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.archive_lead_v1(uuid,uuid,text,integer,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_lead_activity_v1(uuid,uuid,text,text,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_lead_activities_v1(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_lead_follow_up_v1(uuid,uuid,timestamptz,text,uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_lead_follow_ups_v1(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_lead_follow_up_v1(uuid,uuid,text,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_client_v1(uuid,text,text,text,text,text,text,text,uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_clients_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_client_v1(uuid,uuid,text,text,text,text,text,text,text,integer,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.archive_client_v1(uuid,uuid,text,integer,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.convert_lead_to_client_v1(uuid,uuid,text,uuid) TO authenticated;

COMMENT ON TABLE public.crm_activities IS 'Append-only tenant-scoped lead activity evidence for CRM V1.';
COMMENT ON TABLE public.crm_follow_ups IS 'Tenant-scoped human follow-up queue; no automatic external delivery.';
