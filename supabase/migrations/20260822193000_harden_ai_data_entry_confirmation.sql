-- Harden the human-confirmed AI data-entry boundary after PR review.
-- Human callers may claim a reviewed draft, but only the trusted server/service
-- boundary may record application progress or map intake images after the
-- deterministic source-record commands have actually succeeded.

ALTER TABLE public.ai_data_entry_drafts
  ADD COLUMN IF NOT EXISTS confirmation_execution_token uuid,
  ADD COLUMN IF NOT EXISTS confirmation_execution_claimed_at timestamptz;

ALTER TABLE public.ai_data_entry_drafts
  DROP CONSTRAINT IF EXISTS ai_data_entry_draft_execution_claim_consistency;
ALTER TABLE public.ai_data_entry_drafts
  ADD CONSTRAINT ai_data_entry_draft_execution_claim_consistency
  CHECK ((confirmation_execution_token IS NULL) = (confirmation_execution_claimed_at IS NULL));

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
    IF v_existing.draft_id = p_draft_id
      AND v_existing.storage_path = p_storage_path
      AND v_existing.mime_type = p_mime_type
      AND v_existing.byte_size = p_byte_size
      AND v_existing.checksum_sha256 IS NOT DISTINCT FROM p_checksum_sha256 THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'AI data-entry input idempotency key belongs to different input' USING ERRCODE = '23505';
  END IF;

  IF v_draft.status <> 'collecting' THEN RAISE EXCEPTION 'AI data-entry draft is not accepting inputs' USING ERRCODE = '40001'; END IF;
  IF v_draft.expires_at <= timezone('utc', now()) THEN
    UPDATE public.ai_data_entry_drafts
    SET status = 'expired', version = version + 1
    WHERE organization_id = p_organization_id AND id = p_draft_id;
    RETURN NULL;
  END IF;

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
  )
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT input.* INTO v_existing
    FROM public.ai_data_entry_inputs AS input
    WHERE input.organization_id = p_organization_id AND input.idempotency_key = btrim(p_idempotency_key);
    IF NOT FOUND
      OR v_existing.draft_id <> p_draft_id
      OR v_existing.storage_path <> p_storage_path
      OR v_existing.mime_type <> p_mime_type
      OR v_existing.byte_size <> p_byte_size
      OR v_existing.checksum_sha256 IS DISTINCT FROM p_checksum_sha256 THEN
      RAISE EXCEPTION 'AI data-entry input idempotency key belongs to different input' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

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
  IF v_draft.expires_at <= timezone('utc', now()) THEN
    UPDATE public.ai_data_entry_drafts
    SET status = 'expired', version = version + 1
    WHERE organization_id = p_organization_id AND id = p_draft_id;
    INSERT INTO public.audit_events (
      organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta
    ) VALUES (
      p_organization_id, 'user', v_actor, 'ai.data_entry.expired', 'ai_data_entry_draft', p_draft_id, 'success', p_request_id,
      jsonb_build_object('status', 'expired')
    );
    RETURN NULL;
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

CREATE OR REPLACE FUNCTION public.claim_ai_data_entry_confirmation_v2(
  p_organization_id uuid,
  p_draft_id uuid,
  p_confirmation_payload jsonb,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS TABLE (outcome text, execution_token uuid, draft_version integer, application_result jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_role text;
  v_draft public.ai_data_entry_drafts%ROWTYPE;
  v_token uuid;
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

  IF v_draft.status = 'applied' AND v_draft.confirmation_idempotency_key = btrim(p_idempotency_key) THEN
    RETURN QUERY SELECT 'applied'::text, NULL::uuid, v_draft.version, v_draft.application_result;
    RETURN;
  END IF;
  IF v_draft.status = 'expired' THEN
    RETURN QUERY SELECT 'expired'::text, NULL::uuid, v_draft.version, v_draft.application_result;
    RETURN;
  END IF;
  IF v_draft.status = 'confirmed' AND v_draft.confirmation_execution_token IS NOT NULL
    AND v_draft.confirmation_execution_claimed_at > timezone('utc', now()) - interval '10 minutes' THEN
    RETURN QUERY SELECT 'in_progress'::text, NULL::uuid, v_draft.version, v_draft.application_result;
    RETURN;
  END IF;
  IF v_draft.status NOT IN ('ready_for_review', 'partially_applied', 'confirmed') THEN
    RAISE EXCEPTION 'AI data-entry draft is not confirmable' USING ERRCODE = '40001';
  END IF;
  IF v_draft.version <> p_expected_version THEN RAISE EXCEPTION 'AI data-entry draft version is stale' USING ERRCODE = '40001'; END IF;
  IF v_draft.expires_at <= timezone('utc', now()) THEN
    UPDATE public.ai_data_entry_drafts
    SET status = 'expired', version = version + 1,
        confirmation_execution_token = NULL, confirmation_execution_claimed_at = NULL
    WHERE organization_id = p_organization_id AND id = p_draft_id;
    SELECT draft.* INTO v_draft FROM public.ai_data_entry_drafts AS draft
    WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id;
    RETURN QUERY SELECT 'expired'::text, NULL::uuid, v_draft.version, v_draft.application_result;
    RETURN;
  END IF;

  v_token := gen_random_uuid();
  UPDATE public.ai_data_entry_drafts
  SET status = 'confirmed', confirmation_payload = p_confirmation_payload,
      confirmation_idempotency_key = btrim(p_idempotency_key), confirmed_by_membership_id = v_actor,
      confirmed_at = coalesce(confirmed_at, timezone('utc', now())),
      confirmation_execution_token = v_token, confirmation_execution_claimed_at = timezone('utc', now()),
      version = version + 1, error_code = NULL
  WHERE organization_id = p_organization_id AND id = p_draft_id
  RETURNING version, application_result INTO v_draft.version, v_draft.application_result;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.confirmation_claimed', 'ai_data_entry_draft', p_draft_id, 'success', p_request_id,
    jsonb_build_object('confirmation_key', btrim(p_idempotency_key))
  );
  RETURN QUERY SELECT 'claimed'::text, v_token, v_draft.version, v_draft.application_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_ai_data_entry_confirmation_v2(
  p_organization_id uuid,
  p_draft_id uuid,
  p_execution_token uuid,
  p_status text,
  p_application_result jsonb,
  p_expected_version integer,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_draft public.ai_data_entry_drafts%ROWTYPE;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_execution_token IS NULL
    OR p_status NOT IN ('partially_applied', 'applied')
    OR p_application_result IS NULL OR jsonb_typeof(p_application_result) <> 'object' OR char_length(p_application_result::text) > 20000
    OR p_expected_version IS NULL OR p_expected_version < 1 THEN
    RAISE EXCEPTION 'AI data-entry trusted progress input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
  FOR UPDATE;
  IF NOT FOUND OR v_draft.status <> 'confirmed'
    OR v_draft.confirmation_execution_token IS DISTINCT FROM p_execution_token
    OR v_draft.version <> p_expected_version THEN
    RAISE EXCEPTION 'AI data-entry trusted progress claim is stale' USING ERRCODE = '40001';
  END IF;

  UPDATE public.ai_data_entry_drafts
  SET status = p_status, application_result = p_application_result,
      progress_idempotency_key = 'trusted:' || p_execution_token::text,
      confirmation_execution_token = NULL, confirmation_execution_claimed_at = NULL,
      version = version + 1
  WHERE organization_id = p_organization_id AND id = p_draft_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_draft.confirmed_by_membership_id, 'ai.data_entry.progressed', 'ai_data_entry_draft', p_draft_id, 'success', p_request_id,
    jsonb_build_object('status', p_status)
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_ai_data_entry_input_mapped_v2(
  p_organization_id uuid,
  p_input_id uuid,
  p_property_id uuid,
  p_property_image_id uuid,
  p_execution_token uuid,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_input public.ai_data_entry_inputs%ROWTYPE; v_actor uuid;
BEGIN
  IF p_organization_id IS NULL OR p_input_id IS NULL OR p_property_id IS NULL OR p_property_image_id IS NULL OR p_execution_token IS NULL THEN
    RAISE EXCEPTION 'AI data-entry trusted image mapping input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT input.*, draft.confirmed_by_membership_id INTO v_input, v_actor
  FROM public.ai_data_entry_inputs AS input
  JOIN public.ai_data_entry_drafts AS draft
    ON draft.organization_id = input.organization_id AND draft.id = input.draft_id
  WHERE input.organization_id = p_organization_id AND input.id = p_input_id
    AND draft.status = 'confirmed' AND draft.confirmation_execution_token = p_execution_token
  FOR UPDATE OF input;
  IF NOT FOUND THEN RAISE EXCEPTION 'AI data-entry image mapping claim is stale' USING ERRCODE = '40001'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.property_images AS image
    WHERE image.organization_id = p_organization_id AND image.id = p_property_image_id
      AND image.property_id = p_property_id AND image.status = 'active'
  ) THEN RAISE EXCEPTION 'registered property image is missing' USING ERRCODE = '23503'; END IF;
  IF v_input.status = 'mapped' THEN
    IF v_input.mapped_property_id = p_property_id THEN RETURN true; END IF;
    RAISE EXCEPTION 'AI data-entry input is already mapped' USING ERRCODE = '40001';
  END IF;
  IF v_input.status <> 'active' THEN RAISE EXCEPTION 'AI data-entry input is unavailable' USING ERRCODE = '40001'; END IF;

  UPDATE public.ai_data_entry_inputs
  SET status = 'mapped', mapped_property_id = p_property_id, mapped_at = timezone('utc', now())
  WHERE organization_id = p_organization_id AND id = p_input_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.input.mapped', 'ai_data_entry_input', p_input_id, 'success', p_request_id,
    jsonb_build_object('property_id', p_property_id, 'property_image_id', p_property_image_id)
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_ai_data_entry_extraction_v1(
  p_event_id uuid,
  p_worker_id text,
  p_extraction_payload jsonb,
  p_result_summary jsonb
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE
  v_run public.ai_runs%ROWTYPE;
  v_draft public.ai_data_entry_drafts%ROWTYPE;
  v_event public.outbox_events%ROWTYPE;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0
    OR p_extraction_payload IS NULL OR jsonb_typeof(p_extraction_payload) <> 'object' OR char_length(p_extraction_payload::text) > 20000
    OR p_result_summary IS NULL OR jsonb_typeof(p_result_summary) <> 'object' OR char_length(p_result_summary::text) > 20000 THEN
    RAISE EXCEPTION 'AI data-entry extraction finalization input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT event.* INTO v_event
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id AND event.event_type = 'ai.data_entry.requested'
    AND event.state = 'processing' AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  SELECT run.* INTO v_run FROM public.ai_runs AS run
  WHERE run.organization_id = v_event.organization_id AND run.id::text = v_event.payload ->> 'run_id'
    AND run.agent_kind = 'data_entry' AND run.status = 'running'
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  SELECT draft.* INTO v_draft FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = v_event.organization_id AND draft.id::text = v_event.payload ->> 'draft_id'
    AND draft.ai_run_id = v_run.id AND draft.status = 'extracting'
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  UPDATE public.ai_data_entry_drafts
  SET status = 'ready_for_review', extraction_payload = p_extraction_payload,
      version = version + 1, error_code = NULL
  WHERE organization_id = v_draft.organization_id AND id = v_draft.id;
  UPDATE public.ai_runs
  SET status = 'succeeded', result_summary = p_result_summary,
      finished_at = timezone('utc', now()), error_code = NULL
  WHERE organization_id = v_run.organization_id AND id = v_run.id;
  INSERT INTO public.notifications (
    organization_id, recipient_membership_id, category, title, body,
    resource_type, resource_id, dedupe_key
  ) VALUES (
    v_run.organization_id, v_run.initiated_by_membership_id, 'system', 'اقتراح AI جاهز',
    'اكتمل طلب الاقتراح ويمكن مراجعته من مركز الذكاء.',
    'ai_run', v_run.id, 'ai-run-succeeded:' || v_run.id::text
  ) ON CONFLICT (organization_id, dedupe_key) DO NOTHING;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_client_v1(
  p_organization_id uuid, p_display_name text, p_phone text, p_whatsapp text, p_email text,
  p_nationality text, p_preferred_language text, p_notes text, p_source_lead_id uuid,
  p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_actor uuid;
  v_id uuid;
  v_existing public.clients%ROWTYPE;
  v_phone text := public.crm_normalize_phone(p_phone);
  v_email text := public.crm_normalize_email(p_email);
BEGIN
  IF p_display_name IS NULL OR char_length(btrim(p_display_name)) NOT BETWEEN 1 AND 160
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'client V1 input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'client creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_source_lead_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.leads AS lead_record
    WHERE lead_record.organization_id = p_organization_id AND lead_record.id = p_source_lead_id
  ) THEN RAISE EXCEPTION 'source lead is invalid' USING ERRCODE = '23503'; END IF;

  INSERT INTO public.clients (
    organization_id, display_name, phone, whatsapp, email, normalized_phone, normalized_email,
    nationality, preferred_language, notes, source_lead_id, idempotency_key
  ) VALUES (
    p_organization_id, btrim(p_display_name), NULLIF(btrim(p_phone), ''), NULLIF(btrim(p_whatsapp), ''),
    NULLIF(lower(btrim(p_email)), ''), v_phone, v_email, NULLIF(btrim(p_nationality), ''),
    NULLIF(btrim(p_preferred_language), ''), NULLIF(btrim(p_notes), ''), p_source_lead_id, p_idempotency_key
  )
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT client_record.* INTO v_existing FROM public.clients AS client_record
    WHERE client_record.organization_id = p_organization_id AND client_record.idempotency_key = p_idempotency_key;
    IF NOT FOUND
      OR v_existing.display_name <> btrim(p_display_name)
      OR v_existing.phone IS DISTINCT FROM NULLIF(btrim(p_phone), '')
      OR v_existing.whatsapp IS DISTINCT FROM NULLIF(btrim(p_whatsapp), '')
      OR v_existing.email IS DISTINCT FROM NULLIF(lower(btrim(p_email)), '')
      OR v_existing.normalized_phone IS DISTINCT FROM v_phone
      OR v_existing.normalized_email IS DISTINCT FROM v_email
      OR v_existing.nationality IS DISTINCT FROM NULLIF(btrim(p_nationality), '')
      OR v_existing.preferred_language IS DISTINCT FROM NULLIF(btrim(p_preferred_language), '')
      OR v_existing.notes IS DISTINCT FROM NULLIF(btrim(p_notes), '')
      OR v_existing.source_lead_id IS DISTINCT FROM p_source_lead_id THEN
      RAISE EXCEPTION 'idempotency key belongs to a different client' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'client.created', 'client', v_id, 'success', p_request_id, jsonb_build_object('display_name', btrim(p_display_name), 'source_lead_id', p_source_lead_id));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'client.created', 1, 'client-v1:' || v_id::text, jsonb_build_object('client_id', v_id, 'source_lead_id', p_source_lead_id));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_property_v1(
  p_organization_id uuid,
  p_code text,
  p_name text,
  p_timezone text,
  p_address text,
  p_city text,
  p_unit_label text,
  p_bedrooms integer,
  p_max_guests integer,
  p_operational_notes text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid; v_existing public.properties%ROWTYPE; v_id uuid;
BEGIN
  IF p_organization_id IS NULL OR p_code IS NULL OR char_length(btrim(p_code)) = 0
    OR p_name IS NULL OR char_length(btrim(p_name)) = 0
    OR p_timezone IS NULL OR char_length(btrim(p_timezone)) = 0
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'property input is incomplete' USING ERRCODE = '22023';
  END IF;
  IF (p_bedrooms IS NOT NULL AND (p_bedrooms < 0 OR p_bedrooms > 100))
    OR (p_max_guests IS NOT NULL AND (p_max_guests < 1 OR p_max_guests > 1000)) THEN
    RAISE EXCEPTION 'property capacity is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'property creation is not permitted' USING ERRCODE = '42501'; END IF;

  INSERT INTO public.properties (
    organization_id, code, name, timezone, address, city, unit_label,
    bedrooms, max_guests, operational_notes, status, idempotency_key
  ) VALUES (
    p_organization_id, btrim(p_code), btrim(p_name), btrim(p_timezone),
    NULLIF(btrim(p_address), ''), NULLIF(btrim(p_city), ''), NULLIF(btrim(p_unit_label), ''),
    p_bedrooms, p_max_guests, NULLIF(btrim(p_operational_notes), ''), 'active', p_idempotency_key
  )
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT property_record.* INTO v_existing FROM public.properties AS property_record
    WHERE property_record.organization_id = p_organization_id AND property_record.idempotency_key = p_idempotency_key;
    IF NOT FOUND
      OR v_existing.code <> btrim(p_code)
      OR v_existing.name <> btrim(p_name)
      OR v_existing.timezone <> btrim(p_timezone)
      OR v_existing.address IS DISTINCT FROM NULLIF(btrim(p_address), '')
      OR v_existing.city IS DISTINCT FROM NULLIF(btrim(p_city), '')
      OR v_existing.unit_label IS DISTINCT FROM NULLIF(btrim(p_unit_label), '')
      OR v_existing.bedrooms IS DISTINCT FROM p_bedrooms
      OR v_existing.max_guests IS DISTINCT FROM p_max_guests
      OR v_existing.operational_notes IS DISTINCT FROM NULLIF(btrim(p_operational_notes), '')
      OR v_existing.status <> 'active' THEN
      RAISE EXCEPTION 'idempotency key belongs to a different property' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'property.created', 'property', v_id, 'success', p_request_id,
    jsonb_build_object('code', btrim(p_code), 'name', btrim(p_name), 'status', 'active', 'city', NULLIF(btrim(p_city), ''))
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'property.created', 1, 'property-v1:' || v_id::text, jsonb_build_object('property_id', v_id));
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.begin_ai_data_entry_confirmation_v1(uuid,uuid,jsonb,integer,text,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_ai_data_entry_progress_v1(uuid,uuid,text,jsonb,integer,text,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_ai_data_entry_input_mapped_v1(uuid,uuid,uuid,uuid) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.claim_ai_data_entry_confirmation_v2(uuid,uuid,jsonb,integer,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_ai_data_entry_confirmation_v2(uuid,uuid,jsonb,integer,text,uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.finalize_ai_data_entry_confirmation_v2(uuid,uuid,uuid,text,jsonb,integer,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_ai_data_entry_confirmation_v2(uuid,uuid,uuid,text,jsonb,integer,uuid) TO service_role;

REVOKE ALL ON FUNCTION public.mark_ai_data_entry_input_mapped_v2(uuid,uuid,uuid,uuid,uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_ai_data_entry_input_mapped_v2(uuid,uuid,uuid,uuid,uuid,uuid) TO service_role;

REVOKE ALL ON FUNCTION public.finalize_ai_data_entry_extraction_v1(uuid,text,jsonb,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_ai_data_entry_extraction_v1(uuid,text,jsonb,jsonb) TO voya_outbox_worker, service_role;
