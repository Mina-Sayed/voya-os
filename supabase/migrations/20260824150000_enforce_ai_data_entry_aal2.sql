-- Require MFA assurance level 2 at the database boundary for every
-- authenticated AI data-entry RPC. The workspace UI already enforces MFA,
-- but PostgREST RPCs are independently callable by authenticated JWTs.

CREATE OR REPLACE FUNCTION public.ai_data_entry_require_aal2_v1()
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog
AS $$
BEGIN
  IF coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' THEN
    RAISE EXCEPTION 'AI data-entry requires MFA assurance level 2' USING ERRCODE = '42501';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.ai_data_entry_require_aal2_v1() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_source_text text,
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
  v_existing public.ai_data_entry_drafts%ROWTYPE;
  v_id uuid;
BEGIN
  PERFORM public.ai_data_entry_require_aal2_v1();

  IF p_organization_id IS NULL
    OR p_source_text IS NULL
    OR char_length(p_source_text) > 12000
    OR p_idempotency_key IS NULL
    OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI data-entry draft input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id, membership.role INTO v_actor, v_role
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
    IF v_existing.created_by_membership_id = v_actor
      AND v_existing.source_text = p_source_text THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'AI data-entry draft idempotency key belongs to different input' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.ai_data_entry_drafts (
    organization_id, created_by_membership_id, source_kind, source_text,
    status, idempotency_key, expires_at
  ) VALUES (
    p_organization_id,
    v_actor,
    'text',
    p_source_text,
    'collecting',
    btrim(p_idempotency_key),
    timezone('utc', now()) + interval '24 hours'
  ) RETURNING id INTO v_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.draft_created',
    'ai_data_entry_draft', v_id, 'success', p_request_id,
    jsonb_build_object('source_kind', 'text')
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
  PERFORM public.ai_data_entry_require_aal2_v1();

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
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'AI data-entry input registration is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
    AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI data-entry draft is not permitted' USING ERRCODE = '42501';
  END IF;
  IF v_draft.status <> 'collecting' THEN
    RAISE EXCEPTION 'AI data-entry draft is not accepting inputs' USING ERRCODE = '40001';
  END IF;
  IF v_draft.expires_at <= timezone('utc', now()) THEN
    UPDATE public.ai_data_entry_drafts
    SET status = 'expired', version = version + 1
    WHERE organization_id = p_organization_id AND id = p_draft_id;
    RETURN NULL;
  END IF;

  SELECT input.* INTO v_existing
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.draft_id = p_draft_id
      AND v_existing.storage_path = p_storage_path
      AND v_existing.mime_type = p_mime_type
      AND v_existing.byte_size = p_byte_size
      AND v_existing.checksum_sha256 IS NOT DISTINCT FROM p_checksum_sha256
      AND v_existing.status = 'active' THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'AI data-entry input idempotency key belongs to different input' USING ERRCODE = '23505';
  END IF;

  SELECT count(*)::integer, coalesce(sum(input.byte_size), 0)::bigint
    INTO v_active_count, v_total_bytes
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = p_draft_id
    AND input.status IN ('active', 'mapped');
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
    WHERE input.organization_id = p_organization_id
      AND input.idempotency_key = btrim(p_idempotency_key);
    IF NOT FOUND
      OR v_existing.draft_id <> p_draft_id
      OR v_existing.storage_path <> p_storage_path
      OR v_existing.mime_type <> p_mime_type
      OR v_existing.byte_size <> p_byte_size
      OR v_existing.checksum_sha256 IS DISTINCT FROM p_checksum_sha256
      OR v_existing.status <> 'active' THEN
      RAISE EXCEPTION 'AI data-entry input idempotency key belongs to different input' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  UPDATE public.ai_data_entry_drafts
  SET source_kind = CASE WHEN source_text = '' THEN 'image' ELSE 'mixed' END,
      version = version + 1
  WHERE organization_id = p_organization_id AND id = p_draft_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.input.registered',
    'ai_data_entry_input', v_id, 'success', p_request_id,
    jsonb_build_object('draft_id', p_draft_id, 'mime_type', p_mime_type, 'byte_size', p_byte_size)
  );
  RETURN v_id;
END;
$$;

-- Wrap the remaining user RPCs instead of relying on the application MFA gate.
-- Re-create them with an AAL2 precondition while preserving their current body.
-- The explicit checks below are intentionally first in each function.

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
  PERFORM public.ai_data_entry_require_aal2_v1();

  IF p_organization_id IS NULL OR p_draft_id IS NULL
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI data-entry submission input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'AI data-entry submission is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
    AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI data-entry draft is not permitted' USING ERRCODE = '42501';
  END IF;
  IF v_draft.status <> 'collecting' THEN
    IF v_draft.submit_idempotency_key = btrim(p_idempotency_key)
      AND v_draft.ai_run_id IS NOT NULL THEN
      RETURN v_draft.ai_run_id;
    END IF;
    RAISE EXCEPTION 'AI data-entry draft is not accepting submission' USING ERRCODE = '40001';
  END IF;
  IF v_draft.expires_at <= timezone('utc', now()) THEN
    UPDATE public.ai_data_entry_drafts
    SET status = 'expired', version = version + 1
    WHERE organization_id = p_organization_id AND id = p_draft_id;
    INSERT INTO public.audit_events (
      organization_id, actor_type, actor_membership_id, action, resource_type,
      resource_id, outcome, request_id, after_delta
    ) VALUES (
      p_organization_id, 'user', v_actor, 'ai.data_entry.expired',
      'ai_data_entry_draft', p_draft_id, 'success', p_request_id,
      jsonb_build_object('status', 'expired')
    );
    RETURN NULL;
  END IF;

  SELECT count(*)::integer INTO v_input_count
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = p_draft_id AND input.status = 'active';
  IF char_length(v_draft.source_text) = 0 AND v_input_count = 0 THEN
    RAISE EXCEPTION 'AI data-entry draft has no source content' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.ai_runs (
    organization_id, agent_kind, agent_version, status, purpose, model_name,
    prompt_version, initiated_by_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, 'data_entry', 'registry-v1', 'queued',
    'استخراج مسودة إدخال بيانات', 'unconfigured', 'unconfigured',
    v_actor, 'data-entry:' || p_draft_id::text || ':' || btrim(p_idempotency_key)
  ) RETURNING id INTO v_run_id;
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'ai.data_entry.requested', 1,
    'ai-data-entry:' || v_run_id::text,
    jsonb_build_object('run_id', v_run_id, 'draft_id', p_draft_id, 'agent_kind', 'data_entry')
  );
  UPDATE public.ai_data_entry_drafts
  SET status = 'queued', ai_run_id = v_run_id,
      submit_idempotency_key = btrim(p_idempotency_key), version = version + 1
  WHERE organization_id = p_organization_id AND id = p_draft_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.submitted',
    'ai_data_entry_draft', p_draft_id, 'success', p_request_id,
    jsonb_build_object('run_id', v_run_id, 'input_count', v_input_count)
  );
  RETURN v_run_id;
END;
$$;

-- Read/confirmation/rejection RPCs are redefined in the next block from their
-- current contracts with the same first-line AAL2 guard.
