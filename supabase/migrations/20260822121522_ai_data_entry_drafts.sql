-- Voya OS: governed AI data-entry drafts.
-- Gemini may prepare bounded proposals; only explicit confirmation may call
-- the existing CRM/property commands. Raw intake files remain private.

-- The original AI lifecycle RPCs only accepted ai.run.requested. The governed
-- data-entry event uses the same run lifecycle but has its own event type.
CREATE OR REPLACE FUNCTION public.mark_ai_run_started(
  p_event_id uuid,
  p_worker_id text,
  p_model_name text,
  p_prompt_version text
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_run_id uuid;
BEGIN
  IF p_model_name IS NULL OR char_length(btrim(p_model_name)) NOT BETWEEN 1 AND 120
    OR p_prompt_version IS NULL OR char_length(btrim(p_prompt_version)) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'AI execution metadata is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.ai_runs AS run
  SET status = 'running', model_name = btrim(p_model_name), prompt_version = btrim(p_prompt_version),
      started_at = coalesce(run.started_at, timezone('utc', now())), finished_at = NULL, error_code = NULL
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id AND event.event_type IN ('ai.run.requested', 'ai.data_entry.requested')
    AND event.state = 'processing' AND event.locked_by = p_worker_id AND event.locked_until > timezone('utc', now())
    AND run.id::text = event.payload ->> 'run_id' AND run.organization_id = event.organization_id
    AND run.status IN ('queued', 'running')
  RETURNING run.id INTO v_run_id;
  RETURN v_run_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_ai_run_succeeded(
  p_event_id uuid,
  p_worker_id text,
  p_result_summary jsonb
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_run_id uuid; v_organization_id uuid; v_membership_id uuid; v_updated_count integer;
BEGIN
  IF p_result_summary IS NULL OR jsonb_typeof(p_result_summary) <> 'object' OR char_length(p_result_summary::text) > 20000 THEN RAISE EXCEPTION 'AI result summary is invalid' USING ERRCODE = '22023'; END IF;
  UPDATE public.ai_runs AS run
  SET status = 'succeeded', result_summary = p_result_summary, finished_at = timezone('utc', now()), error_code = NULL
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id AND event.event_type IN ('ai.run.requested', 'ai.data_entry.requested')
    AND event.state = 'processing' AND event.locked_by = p_worker_id AND event.locked_until > timezone('utc', now())
    AND run.id::text = event.payload ->> 'run_id' AND run.organization_id = event.organization_id
    AND run.status IN ('queued', 'running')
  RETURNING run.id, run.organization_id, run.initiated_by_membership_id INTO v_run_id, v_organization_id, v_membership_id;
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count = 1 THEN
    INSERT INTO public.notifications (organization_id, recipient_membership_id, category, title, body, resource_type, resource_id, dedupe_key)
    VALUES (v_organization_id, v_membership_id, 'system', 'اقتراح AI جاهز', 'اكتمل طلب الاقتراح ويمكن مراجعته من مركز الذكاء.', 'ai_run', v_run_id, 'ai-run-succeeded:' || v_run_id::text)
    ON CONFLICT (organization_id, dedupe_key) DO NOTHING;
  END IF;
  RETURN v_updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_ai_run_failed(
  p_event_id uuid,
  p_worker_id text,
  p_error_code text
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_run_id uuid; v_organization_id uuid; v_membership_id uuid; v_updated_count integer;
BEGIN
  IF p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$' THEN RAISE EXCEPTION 'AI error code is invalid' USING ERRCODE = '22023'; END IF;
  UPDATE public.ai_runs AS run
  SET status = 'failed', finished_at = timezone('utc', now()), error_code = p_error_code
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id AND event.event_type IN ('ai.run.requested', 'ai.data_entry.requested')
    AND event.state = 'processing' AND event.locked_by = p_worker_id AND event.locked_until > timezone('utc', now())
    AND run.id::text = event.payload ->> 'run_id' AND run.organization_id = event.organization_id
    AND run.status IN ('queued', 'running');
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count = 1 THEN
    SELECT run.id, run.organization_id, run.initiated_by_membership_id INTO v_run_id, v_organization_id, v_membership_id
    FROM public.ai_runs AS run JOIN public.outbox_events AS event ON event.id = p_event_id AND event.organization_id = run.organization_id
    WHERE run.id::text = event.payload ->> 'run_id';
    INSERT INTO public.notifications (organization_id, recipient_membership_id, category, title, body, resource_type, resource_id, dedupe_key)
    VALUES (v_organization_id, v_membership_id, 'system', 'تعذر إكمال اقتراح AI', 'تعذر تشغيل طلب الاقتراح. راجع الإعدادات أو أعد الطلب يدوياً.', 'ai_run', v_run_id, 'ai-run-failed:' || v_run_id::text || ':' || p_error_code)
    ON CONFLICT (organization_id, dedupe_key) DO NOTHING;
  END IF;
  RETURN v_updated_count = 1;
END;
$$;

ALTER TABLE public.ai_runs
  DROP CONSTRAINT IF EXISTS ai_runs_agent_kind_check;

ALTER TABLE public.ai_runs
  ADD CONSTRAINT ai_runs_agent_kind_check
  CHECK (agent_kind IN ('sales', 'booking', 'finance', 'manager', 'copilot', 'data_entry')) NOT VALID;

ALTER TABLE public.ai_runs VALIDATE CONSTRAINT ai_runs_agent_kind_check;

CREATE TABLE public.ai_data_entry_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ai_run_id uuid,
  created_by_membership_id uuid NOT NULL,
  confirmed_by_membership_id uuid,
  status text NOT NULL DEFAULT 'collecting'
    CHECK (status IN ('collecting', 'queued', 'extracting', 'ready_for_review', 'confirmed', 'partially_applied', 'applied', 'rejected', 'expired', 'failed')),
  source_text text NOT NULL DEFAULT '',
  source_kind text NOT NULL DEFAULT 'text'
    CHECK (source_kind IN ('text', 'image', 'mixed')),
  extraction_payload jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(extraction_payload) = 'object'),
  confirmation_payload jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(confirmation_payload) = 'object'),
  application_result jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(application_result) = 'object'),
  error_code text
    CHECK (error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  submit_idempotency_key text
    CHECK (submit_idempotency_key IS NULL OR char_length(btrim(submit_idempotency_key)) BETWEEN 1 AND 160),
  confirmation_idempotency_key text
    CHECK (confirmation_idempotency_key IS NULL OR char_length(btrim(confirmation_idempotency_key)) BETWEEN 1 AND 160),
  progress_idempotency_key text
    CHECK (progress_idempotency_key IS NULL OR char_length(btrim(progress_idempotency_key)) BETWEEN 1 AND 160),
  rejection_idempotency_key text
    CHECK (rejection_idempotency_key IS NULL OR char_length(btrim(rejection_idempotency_key)) BETWEEN 1 AND 160),
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  expires_at timestamptz NOT NULL DEFAULT timezone('utc', now()) + interval '24 hours',
  confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, idempotency_key),
  UNIQUE (organization_id, submit_idempotency_key),
  UNIQUE (organization_id, confirmation_idempotency_key),
  UNIQUE (organization_id, progress_idempotency_key),
  UNIQUE (organization_id, rejection_idempotency_key),
  CONSTRAINT ai_data_entry_draft_creator_tenant_fk
    FOREIGN KEY (organization_id, created_by_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT ai_data_entry_draft_confirmer_tenant_fk
    FOREIGN KEY (organization_id, confirmed_by_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT ai_data_entry_draft_run_tenant_fk
    FOREIGN KEY (organization_id, ai_run_id)
    REFERENCES public.ai_runs(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT ai_data_entry_draft_source_length_check
    CHECK (char_length(source_text) <= 20000),
  CONSTRAINT ai_data_entry_draft_confirmed_consistency_check
    CHECK ((status IN ('confirmed', 'partially_applied', 'applied') AND confirmed_at IS NOT NULL AND confirmed_by_membership_id IS NOT NULL)
      OR (status NOT IN ('confirmed', 'partially_applied', 'applied')))
);

CREATE TABLE public.ai_data_entry_inputs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  draft_id uuid NOT NULL,
  created_by_membership_id uuid NOT NULL,
  storage_bucket text NOT NULL DEFAULT 'ai-intake' CHECK (storage_bucket = 'ai-intake'),
  storage_path text NOT NULL,
  mime_type text NOT NULL CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/webp')),
  byte_size bigint NOT NULL CHECK (byte_size > 0 AND byte_size <= 10485760),
  checksum_sha256 text CHECK (checksum_sha256 IS NULL OR checksum_sha256 ~ '^[0-9a-f]{64}$'),
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'mapped', 'archived')),
  mapped_property_id uuid,
  mapped_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, idempotency_key),
  CONSTRAINT ai_data_entry_input_draft_tenant_fk
    FOREIGN KEY (organization_id, draft_id)
    REFERENCES public.ai_data_entry_drafts(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT ai_data_entry_input_creator_tenant_fk
    FOREIGN KEY (organization_id, created_by_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT ai_data_entry_input_property_tenant_fk
    FOREIGN KEY (organization_id, mapped_property_id)
    REFERENCES public.properties(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT ai_data_entry_input_path_shape_check
    CHECK (storage_path = lower(storage_path)
      AND storage_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'),
  CONSTRAINT ai_data_entry_input_mapping_consistency_check
    CHECK ((status = 'mapped' AND mapped_property_id IS NOT NULL AND mapped_at IS NOT NULL)
      OR (status <> 'mapped' AND mapped_property_id IS NULL AND mapped_at IS NULL))
);

CREATE INDEX ai_data_entry_drafts_visibility_idx
  ON public.ai_data_entry_drafts (organization_id, created_by_membership_id, created_at DESC);
CREATE INDEX ai_data_entry_inputs_draft_idx
  ON public.ai_data_entry_inputs (organization_id, draft_id, created_at ASC);

CREATE TRIGGER ai_data_entry_drafts_set_updated_at
  BEFORE UPDATE ON public.ai_data_entry_drafts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.ai_data_entry_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_data_entry_drafts FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ai_data_entry_inputs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_data_entry_inputs FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ai_data_entry_drafts, public.ai_data_entry_inputs FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF to_regclass('storage.buckets') IS NOT NULL THEN
    EXECUTE $storage$
      INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
      VALUES ('ai-intake', 'ai-intake', false, 10485760, ARRAY['image/jpeg', 'image/png', 'image/webp']::text[])
      ON CONFLICT (id) DO UPDATE
        SET name = EXCLUDED.name,
            public = false,
            file_size_limit = EXCLUDED.file_size_limit,
            allowed_mime_types = EXCLUDED.allowed_mime_types
    $storage$;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_source_text text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_existing public.ai_data_entry_drafts%ROWTYPE;
  v_id uuid;
  v_source text := coalesce(p_source_text, '');
BEGIN
  IF p_organization_id IS NULL
    OR char_length(v_source) > 20000
    OR p_idempotency_key IS NULL
    OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI data-entry draft input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'AI data-entry draft creation is not permitted' USING ERRCODE = '42501';
  END IF;
  SELECT draft.* INTO v_existing
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.source_text = v_source THEN RETURN v_existing.id; END IF;
    RAISE EXCEPTION 'AI data-entry draft idempotency key belongs to different input' USING ERRCODE = '23505';
  END IF;
  INSERT INTO public.ai_data_entry_drafts (
    organization_id, created_by_membership_id, source_text, source_kind, idempotency_key
  ) VALUES (
    p_organization_id, v_actor, v_source, CASE WHEN v_source = '' THEN 'image' ELSE 'text' END, btrim(p_idempotency_key)
  )
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT draft.* INTO v_existing
    FROM public.ai_data_entry_drafts AS draft
    WHERE draft.organization_id = p_organization_id
      AND draft.idempotency_key = btrim(p_idempotency_key);
    IF NOT FOUND OR v_existing.source_text <> v_source THEN
      RAISE EXCEPTION 'AI data-entry draft idempotency key belongs to different input' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.draft.created', 'ai_data_entry_draft', v_id, 'success', p_request_id,
    jsonb_build_object('source_kind', CASE WHEN v_source = '' THEN 'image' ELSE 'text' END)
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.register_ai_data_entry_input_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_checksum_sha256 text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_role text;
  v_draft public.ai_data_entry_drafts%ROWTYPE;
  v_existing public.ai_data_entry_inputs%ROWTYPE;
  v_id uuid;
  v_active_count integer;
  v_total_bytes bigint;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL
    OR p_storage_path IS NULL OR p_storage_path <> lower(p_storage_path)
    OR p_storage_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'
    OR split_part(p_storage_path, '/', 1) <> p_organization_id::text
    OR split_part(p_storage_path, '/', 2) <> p_draft_id::text
    OR p_mime_type NOT IN ('image/jpeg', 'image/png', 'image/webp')
    OR p_byte_size IS NULL OR p_byte_size < 1 OR p_byte_size > 10485760
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI data-entry input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_checksum_sha256 IS NOT NULL AND p_checksum_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'AI data-entry checksum is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AI data-entry input registration is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
    AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AI data-entry draft is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT input.* INTO v_existing
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id AND input.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.draft_id = p_draft_id AND v_existing.storage_path = p_storage_path AND v_existing.byte_size = p_byte_size THEN RETURN v_existing.id; END IF;
    RAISE EXCEPTION 'AI data-entry input idempotency key belongs to different input' USING ERRCODE = '23505';
  END IF;
  IF v_draft.status <> 'collecting' THEN RAISE EXCEPTION 'AI data-entry draft is not accepting inputs' USING ERRCODE = '40001'; END IF;
  SELECT count(*)::integer, coalesce(sum(input.byte_size), 0)::bigint
    INTO v_active_count, v_total_bytes
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id AND input.draft_id = p_draft_id AND input.status IN ('active', 'mapped');
  IF v_active_count >= 20 OR v_total_bytes + p_byte_size > 26214400 THEN
    RAISE EXCEPTION 'AI data-entry input limit exceeded' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.ai_data_entry_inputs (
    organization_id, draft_id, created_by_membership_id, storage_path, mime_type,
    byte_size, checksum_sha256, idempotency_key
  ) VALUES (
    p_organization_id, p_draft_id, v_actor, p_storage_path, p_mime_type,
    p_byte_size, p_checksum_sha256, btrim(p_idempotency_key)
  ) RETURNING id INTO v_id;
  UPDATE public.ai_data_entry_drafts
  SET source_kind = CASE WHEN source_text = '' THEN 'image' ELSE 'mixed' END,
      version = version + 1
  WHERE organization_id = p_organization_id AND id = p_draft_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.input.registered', 'ai_data_entry_input', v_id, 'success', p_request_id,
    jsonb_build_object('draft_id', p_draft_id, 'mime_type', p_mime_type, 'byte_size', p_byte_size)
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_role text;
  v_draft public.ai_data_entry_drafts%ROWTYPE;
  v_run_id uuid;
  v_input_count integer;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI data-entry submission input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AI data-entry submission is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
    AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AI data-entry draft is not permitted' USING ERRCODE = '42501'; END IF;
  IF v_draft.status <> 'collecting' THEN
    IF v_draft.submit_idempotency_key = btrim(p_idempotency_key) AND v_draft.ai_run_id IS NOT NULL THEN RETURN v_draft.ai_run_id; END IF;
    RAISE EXCEPTION 'AI data-entry draft is not accepting submission' USING ERRCODE = '40001';
  END IF;
  SELECT count(*)::integer INTO v_input_count
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id AND input.draft_id = p_draft_id AND input.status = 'active';
  IF char_length(v_draft.source_text) = 0 AND v_input_count = 0 THEN RAISE EXCEPTION 'AI data-entry draft has no source content' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.ai_runs (
    organization_id, agent_kind, agent_version, status, purpose, model_name, prompt_version,
    initiated_by_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, 'data_entry', 'registry-v1', 'queued', 'استخراج مسودة إدخال بيانات', 'unconfigured', 'unconfigured',
    v_actor, 'data-entry:' || p_draft_id::text || ':' || btrim(p_idempotency_key)
  ) RETURNING id INTO v_run_id;
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id, 'ai.data_entry.requested', 1, 'ai-data-entry:' || v_run_id::text,
    jsonb_build_object('run_id', v_run_id, 'draft_id', p_draft_id, 'agent_kind', 'data_entry')
  );
  UPDATE public.ai_data_entry_drafts
  SET status = 'queued', ai_run_id = v_run_id, submit_idempotency_key = btrim(p_idempotency_key), version = version + 1
  WHERE organization_id = p_organization_id AND id = p_draft_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.submitted', 'ai_data_entry_draft', p_draft_id, 'success', p_request_id,
    jsonb_build_object('run_id', v_run_id, 'input_count', v_input_count)
  );
  RETURN v_run_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_ai_data_entry_drafts_v1(
  p_organization_id uuid,
  p_limit integer DEFAULT 30
)
RETURNS TABLE (
  id uuid, ai_run_id uuid, status text, source_kind text, version integer,
  error_code text, expires_at timestamptz, created_at timestamptz, updated_at timestamptz,
  created_by_membership_id uuid, input_count bigint
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN RAISE EXCEPTION 'AI data-entry read is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'AI data-entry limit is invalid' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  SELECT draft.id, draft.ai_run_id, draft.status, draft.source_kind, draft.version, draft.error_code,
    draft.expires_at, draft.created_at, draft.updated_at, draft.created_by_membership_id,
    count(input.id)::bigint
  FROM public.ai_data_entry_drafts AS draft
  LEFT JOIN public.ai_data_entry_inputs AS input
    ON input.organization_id = draft.organization_id AND input.draft_id = draft.id AND input.status IN ('active', 'mapped')
  WHERE draft.organization_id = p_organization_id
    AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  GROUP BY draft.id
  ORDER BY draft.created_at DESC, draft.id DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_draft_id uuid
)
RETURNS TABLE (
  id uuid, ai_run_id uuid, status text, source_text text, source_kind text,
  extraction_payload jsonb, confirmation_payload jsonb, application_result jsonb,
  error_code text, version integer, expires_at timestamptz,
  created_at timestamptz, updated_at timestamptz, created_by_membership_id uuid
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN RAISE EXCEPTION 'AI data-entry read is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY
  SELECT draft.id, draft.ai_run_id, draft.status, draft.source_text, draft.source_kind, draft.extraction_payload,
    draft.confirmation_payload, draft.application_result,
    draft.error_code, draft.version, draft.expires_at, draft.created_at, draft.updated_at, draft.created_by_membership_id
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
    AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor);
END;
$$;

CREATE OR REPLACE FUNCTION public.list_ai_data_entry_inputs_v1(
  p_organization_id uuid,
  p_draft_id uuid
)
RETURNS TABLE (
  id uuid, storage_bucket text, storage_path text, mime_type text, byte_size bigint,
  checksum_sha256 text, status text, mapped_property_id uuid, mapped_at timestamptz, created_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN RAISE EXCEPTION 'AI data-entry input read is not permitted' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.ai_data_entry_drafts AS draft
    WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
      AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  ) THEN RAISE EXCEPTION 'AI data-entry draft is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY
  SELECT input.id, input.storage_bucket, input.storage_path, input.mime_type, input.byte_size,
    input.checksum_sha256, input.status, input.mapped_property_id, input.mapped_at, input.created_at
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id AND input.draft_id = p_draft_id
  ORDER BY input.created_at ASC, input.id ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_ai_data_entry_execution_v1(
  p_event_id uuid,
  p_worker_id text
)
RETURNS TABLE (
  run_id uuid, organization_id uuid, draft_id uuid, agent_kind text, purpose text,
  initiated_by_membership_id uuid, source_text text, inputs jsonb
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 THEN RAISE EXCEPTION 'worker AI data-entry context is invalid' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  SELECT run.id, run.organization_id, draft.id, run.agent_kind, run.purpose,
    run.initiated_by_membership_id, draft.source_text,
    coalesce((SELECT jsonb_agg(jsonb_build_object(
      'id', input.id, 'storage_bucket', input.storage_bucket, 'storage_path', input.storage_path,
      'mime_type', input.mime_type, 'byte_size', input.byte_size
    ) ORDER BY input.created_at, input.id) FROM public.ai_data_entry_inputs AS input
      WHERE input.organization_id = draft.organization_id AND input.draft_id = draft.id AND input.status = 'active'), '[]'::jsonb)
  FROM public.outbox_events AS event
  JOIN public.ai_runs AS run
    ON run.id::text = event.payload ->> 'run_id' AND run.organization_id = event.organization_id
  JOIN public.ai_data_entry_drafts AS draft
    ON draft.organization_id = event.organization_id AND draft.id::text = event.payload ->> 'draft_id'
  WHERE event.id = p_event_id AND event.event_type = 'ai.data_entry.requested'
    AND event.state = 'processing' AND event.locked_by = p_worker_id AND event.locked_until > timezone('utc', now())
    AND run.agent_kind = 'data_entry' AND run.status IN ('queued', 'running')
    AND draft.status IN ('queued', 'extracting');
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_ai_data_entry_extracting_v1(
  p_event_id uuid,
  p_worker_id text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_count integer;
BEGIN
  UPDATE public.ai_data_entry_drafts AS draft
  SET status = 'extracting', version = version + 1, error_code = NULL
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id AND event.event_type = 'ai.data_entry.requested'
    AND event.state = 'processing' AND event.locked_by = p_worker_id AND event.locked_until > timezone('utc', now())
    AND draft.organization_id = event.organization_id AND draft.id::text = event.payload ->> 'draft_id'
    AND draft.status = 'queued';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_ai_data_entry_ready_v1(
  p_event_id uuid,
  p_worker_id text,
  p_extraction_payload jsonb
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_count integer;
BEGIN
  IF p_extraction_payload IS NULL OR jsonb_typeof(p_extraction_payload) <> 'object' OR char_length(p_extraction_payload::text) > 20000 THEN RAISE EXCEPTION 'AI data-entry extraction payload is invalid' USING ERRCODE = '22023'; END IF;
  UPDATE public.ai_data_entry_drafts AS draft
  SET status = 'ready_for_review', extraction_payload = p_extraction_payload, version = version + 1, error_code = NULL
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id AND event.event_type = 'ai.data_entry.requested'
    AND event.state = 'processing' AND event.locked_by = p_worker_id AND event.locked_until > timezone('utc', now())
    AND draft.organization_id = event.organization_id AND draft.id::text = event.payload ->> 'draft_id'
    AND draft.status = 'extracting';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_ai_data_entry_failed_v1(
  p_event_id uuid,
  p_worker_id text,
  p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_count integer;
BEGIN
  IF p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$' THEN RAISE EXCEPTION 'AI data-entry error code is invalid' USING ERRCODE = '22023'; END IF;
  UPDATE public.ai_data_entry_drafts AS draft
  SET status = 'failed', error_code = p_error_code, version = version + 1
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id AND event.event_type = 'ai.data_entry.requested'
    AND event.state = 'processing' AND event.locked_by = p_worker_id AND event.locked_until > timezone('utc', now())
    AND draft.organization_id = event.organization_id AND draft.id::text = event.payload ->> 'draft_id'
    AND draft.status IN ('queued', 'extracting');
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.begin_ai_data_entry_confirmation_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_confirmation_payload jsonb,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_role text; v_draft public.ai_data_entry_drafts%ROWTYPE;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_confirmation_payload IS NULL
    OR jsonb_typeof(p_confirmation_payload) <> 'object' OR char_length(p_confirmation_payload::text) > 20000
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI data-entry confirmation input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AI data-entry confirmation is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
    AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AI data-entry draft is not permitted' USING ERRCODE = '42501'; END IF;
  IF v_draft.confirmation_idempotency_key = btrim(p_idempotency_key) THEN RETURN true; END IF;
  IF v_draft.status NOT IN ('ready_for_review', 'confirmed', 'partially_applied') THEN RAISE EXCEPTION 'AI data-entry draft is not confirmable' USING ERRCODE = '40001'; END IF;
  IF v_draft.version <> p_expected_version THEN RAISE EXCEPTION 'AI data-entry draft version is stale' USING ERRCODE = '40001'; END IF;
  IF v_draft.expires_at <= timezone('utc', now()) THEN
    UPDATE public.ai_data_entry_drafts SET status = 'expired', version = version + 1 WHERE organization_id = p_organization_id AND id = p_draft_id;
    RAISE EXCEPTION 'AI data-entry draft has expired' USING ERRCODE = '40001';
  END IF;
  UPDATE public.ai_data_entry_drafts
  SET status = 'confirmed', confirmation_payload = p_confirmation_payload,
      confirmation_idempotency_key = btrim(p_idempotency_key), confirmed_by_membership_id = v_actor,
      confirmed_at = coalesce(confirmed_at, timezone('utc', now())), version = version + 1, error_code = NULL
  WHERE organization_id = p_organization_id AND id = p_draft_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.confirmed', 'ai_data_entry_draft', p_draft_id, 'success', p_request_id,
    jsonb_build_object('confirmation_key', btrim(p_idempotency_key))
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ai_data_entry_progress_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_status text,
  p_application_result jsonb,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_role text; v_draft public.ai_data_entry_drafts%ROWTYPE;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_status NOT IN ('partially_applied', 'applied')
    OR p_application_result IS NULL OR jsonb_typeof(p_application_result) <> 'object' OR char_length(p_application_result::text) > 20000
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI data-entry progress input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AI data-entry progress is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
    AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AI data-entry draft is not permitted' USING ERRCODE = '42501'; END IF;
  IF v_draft.progress_idempotency_key = btrim(p_idempotency_key) AND v_draft.status = p_status THEN RETURN true; END IF;
  IF v_draft.status NOT IN ('confirmed', 'partially_applied') OR v_draft.version <> p_expected_version THEN RAISE EXCEPTION 'AI data-entry progress version is stale' USING ERRCODE = '40001'; END IF;
  UPDATE public.ai_data_entry_drafts
  SET status = p_status, application_result = p_application_result, progress_idempotency_key = btrim(p_idempotency_key), version = version + 1
  WHERE organization_id = p_organization_id AND id = p_draft_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.progressed', 'ai_data_entry_draft', p_draft_id, 'success', p_request_id,
    jsonb_build_object('status', p_status)
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_role text; v_draft public.ai_data_entry_drafts%ROWTYPE;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI data-entry rejection input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AI data-entry rejection is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT draft.* INTO v_draft FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
    AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AI data-entry draft is not permitted' USING ERRCODE = '42501'; END IF;
  IF v_draft.rejection_idempotency_key = btrim(p_idempotency_key) THEN RETURN true; END IF;
  IF v_draft.status IN ('confirmed', 'partially_applied', 'applied') OR v_draft.version <> p_expected_version THEN RAISE EXCEPTION 'AI data-entry draft cannot be discarded' USING ERRCODE = '40001'; END IF;
  UPDATE public.ai_data_entry_drafts
  SET status = 'rejected', rejection_idempotency_key = btrim(p_idempotency_key), version = version + 1
  WHERE organization_id = p_organization_id AND id = p_draft_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.rejected', 'ai_data_entry_draft', p_draft_id, 'success', p_request_id,
    jsonb_build_object('status', 'rejected')
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_ai_data_entry_input_mapped_v1(
  p_organization_id uuid,
  p_input_id uuid,
  p_property_id uuid,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_role text; v_count integer;
BEGIN
  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AI data-entry image mapping is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_input_id IS NULL OR p_property_id IS NULL THEN RAISE EXCEPTION 'AI data-entry image mapping input is invalid' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.ai_data_entry_inputs AS input
    JOIN public.ai_data_entry_drafts AS draft
      ON draft.organization_id = input.organization_id AND draft.id = input.draft_id
    WHERE input.organization_id = p_organization_id AND input.id = p_input_id
      AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  ) THEN
    RAISE EXCEPTION 'AI data-entry input is not permitted' USING ERRCODE = '42501';
  END IF;
  UPDATE public.ai_data_entry_inputs AS input
  SET status = 'mapped', mapped_property_id = p_property_id, mapped_at = timezone('utc', now())
  WHERE input.organization_id = p_organization_id AND input.id = p_input_id AND input.status = 'active'
    AND EXISTS (
      SELECT 1 FROM public.properties AS property_record
      WHERE property_record.organization_id = p_organization_id AND property_record.id = p_property_id AND property_record.status <> 'archived'
    );
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 AND NOT EXISTS (SELECT 1 FROM public.ai_data_entry_inputs WHERE organization_id = p_organization_id AND id = p_input_id AND status = 'mapped' AND mapped_property_id = p_property_id) THEN
    RAISE EXCEPTION 'AI data-entry image input or property is invalid' USING ERRCODE = '23503';
  END IF;
  IF v_count = 1 THEN
    INSERT INTO public.audit_events (
      organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta
    ) VALUES (
      p_organization_id, 'user', v_actor, 'ai.data_entry.input.mapped', 'ai_data_entry_input', p_input_id, 'success', p_request_id,
      jsonb_build_object('property_id', p_property_id)
    );
  END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_outbox_delivery_events(
  p_worker_id text,
  p_limit integer,
  p_lease_seconds integer
)
RETURNS SETOF public.outbox_events
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
BEGIN
  IF p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120 THEN RAISE EXCEPTION 'worker id is invalid' USING ERRCODE = '22023'; END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 20 THEN RAISE EXCEPTION 'delivery batch must be between 1 and 20' USING ERRCODE = '22023'; END IF;
  IF p_lease_seconds IS NULL OR p_lease_seconds < 1 OR p_lease_seconds > 900 THEN RAISE EXCEPTION 'lease duration must be between 1 and 900 seconds' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  WITH eligible AS (
    SELECT event.id
    FROM public.outbox_events AS event
    WHERE event.event_type IN ('organization.invitation.send_requested', 'member.invitation.resent', 'whatsapp.message.send_requested', 'ai.run.requested', 'ai.data_entry.requested')
      AND ((event.state IN ('pending', 'retry_wait') AND event.available_at <= timezone('utc', now())) OR (event.state = 'processing' AND event.locked_until <= timezone('utc', now())))
    ORDER BY CASE WHEN event.state = 'processing' THEN event.locked_until ELSE event.available_at END ASC, event.created_at ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.outbox_events AS event
  SET state = 'processing', attempts = event.attempts + 1, locked_by = p_worker_id,
      locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds), last_error_code = NULL
  FROM eligible
  WHERE event.id = eligible.id
  RETURNING event.*;
END;
$$;

REVOKE ALL ON FUNCTION public.create_ai_data_entry_draft_v1(uuid,text,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.register_ai_data_entry_input_v1(uuid,uuid,text,text,bigint,text,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.submit_ai_data_entry_draft_v1(uuid,uuid,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_ai_data_entry_drafts_v1(uuid,integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_ai_data_entry_draft_v1(uuid,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_ai_data_entry_inputs_v1(uuid,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.begin_ai_data_entry_confirmation_v1(uuid,uuid,jsonb,integer,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_ai_data_entry_progress_v1(uuid,uuid,text,jsonb,integer,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reject_ai_data_entry_draft_v1(uuid,uuid,integer,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.mark_ai_data_entry_input_mapped_v1(uuid,uuid,uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.create_ai_data_entry_draft_v1(uuid,text,text,uuid),
  public.register_ai_data_entry_input_v1(uuid,uuid,text,text,bigint,text,text,uuid),
  public.submit_ai_data_entry_draft_v1(uuid,uuid,text,uuid),
  public.list_ai_data_entry_drafts_v1(uuid,integer),
  public.get_ai_data_entry_draft_v1(uuid,uuid),
  public.list_ai_data_entry_inputs_v1(uuid,uuid),
  public.begin_ai_data_entry_confirmation_v1(uuid,uuid,jsonb,integer,text,uuid),
  public.record_ai_data_entry_progress_v1(uuid,uuid,text,jsonb,integer,text,uuid),
  public.reject_ai_data_entry_draft_v1(uuid,uuid,integer,text,uuid),
  public.mark_ai_data_entry_input_mapped_v1(uuid,uuid,uuid,uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.resolve_ai_data_entry_execution_v1(uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_ai_data_entry_extracting_v1(uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_ai_data_entry_ready_v1(uuid,text,jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_ai_data_entry_failed_v1(uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.resolve_ai_data_entry_execution_v1(uuid,text),
  public.mark_ai_data_entry_extracting_v1(uuid,text),
  public.mark_ai_data_entry_ready_v1(uuid,text,jsonb),
  public.mark_ai_data_entry_failed_v1(uuid,text,text)
TO voya_outbox_worker, service_role;

COMMENT ON TABLE public.ai_data_entry_drafts IS 'Tenant-scoped, expiring AI extraction proposals; never source-of-record data until human confirmation.';
COMMENT ON TABLE public.ai_data_entry_inputs IS 'Private bounded image inputs for human-reviewed AI data-entry drafts.';
