-- Make AI data-entry private-input cleanup retryable and metadata-consistent.
--
-- Confirmation cleanup archives unused inputs while the trusted execution token
-- is still owned. Every terminal draft transition archives any remaining active
-- intake metadata in the same transaction, and terminal drafts reject upload
-- idempotency replays. Worker terminal failure moves run/draft state before
-- object-storage cleanup.

CREATE OR REPLACE FUNCTION public.archive_ai_data_entry_inputs_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_input_ids uuid[],
  p_execution_token uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_found integer;
  v_updated integer;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_input_ids IS NULL
    OR p_execution_token IS NULL OR cardinality(p_input_ids) > 100
    OR cardinality(p_input_ids) <> (
      SELECT count(DISTINCT input_id)::integer
      FROM unnest(p_input_ids) AS requested(input_id)
    ) THEN
    RAISE EXCEPTION 'AI data-entry input archive request is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT draft.confirmed_by_membership_id INTO v_actor
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.id = p_draft_id
    AND draft.status = 'confirmed'
    AND draft.confirmation_execution_token = p_execution_token
    AND draft.expires_at > timezone('utc', now())
  FOR UPDATE;
  IF NOT FOUND OR v_actor IS NULL THEN
    RAISE EXCEPTION 'AI data-entry input archive claim is stale' USING ERRCODE = '40001';
  END IF;

  IF cardinality(p_input_ids) = 0 THEN
    RETURN true;
  END IF;

  PERFORM 1
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = p_draft_id
    AND input.id = ANY (p_input_ids)
    AND input.status IN ('active', 'archived')
  ORDER BY input.id
  FOR UPDATE;

  SELECT count(*)::integer INTO v_found
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = p_draft_id
    AND input.id = ANY (p_input_ids)
    AND input.status IN ('active', 'archived');
  IF v_found <> cardinality(p_input_ids) THEN
    RAISE EXCEPTION 'AI data-entry input archive set is stale' USING ERRCODE = '40001';
  END IF;

  UPDATE public.ai_data_entry_inputs AS input
  SET status = 'archived'
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = p_draft_id
    AND input.id = ANY (p_input_ids)
    AND input.status = 'active';
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated > 0 THEN
    INSERT INTO public.audit_events (
      organization_id, actor_type, actor_membership_id, action, resource_type,
      resource_id, outcome, after_delta
    ) VALUES (
      p_organization_id, 'user', v_actor, 'ai.data_entry.inputs.archived',
      'ai_data_entry_draft', p_draft_id, 'success',
      jsonb_build_object('input_count', v_updated)
    );
  END IF;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_terminal_ai_data_entry_inputs_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.status IN ('expired', 'rejected', 'failed', 'applied')
    AND OLD.status IS DISTINCT FROM NEW.status THEN
    UPDATE public.ai_data_entry_inputs AS input
    SET status = 'archived'
    WHERE input.organization_id = NEW.organization_id
      AND input.draft_id = NEW.id
      AND input.status = 'active';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS ai_data_entry_drafts_archive_terminal_inputs ON public.ai_data_entry_drafts;
CREATE TRIGGER ai_data_entry_drafts_archive_terminal_inputs
  AFTER UPDATE OF status ON public.ai_data_entry_drafts
  FOR EACH ROW
  EXECUTE FUNCTION public.archive_terminal_ai_data_entry_inputs_v1();

-- The draft lock is acquired before idempotency lookup so an upload replay can
-- never return an archived input from a terminal draft. Expiry is persisted and
-- the terminal trigger archives existing active inputs in the same transaction.
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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
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
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'AI data-entry input registration is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.id = p_draft_id
    AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI data-entry draft is not permitted' USING ERRCODE = '42501';
  END IF;

  IF v_draft.status <> 'collecting' THEN
    RAISE EXCEPTION 'AI data-entry draft is not accepting inputs' USING ERRCODE = '40001';
  END IF;
  IF v_draft.expires_at <= timezone('utc', now()) THEN
    UPDATE public.ai_data_entry_drafts AS draft
    SET status = 'expired', version = draft.version + 1
    WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id;
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

  UPDATE public.ai_data_entry_drafts AS draft
  SET source_kind = CASE WHEN draft.source_text = '' THEN 'image' ELSE 'mixed' END,
      version = draft.version + 1
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id;

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

CREATE OR REPLACE FUNCTION public.finalize_ai_data_entry_failure_v1(
  p_event_id uuid,
  p_worker_id text,
  p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_event public.outbox_events%ROWTYPE;
  v_run public.ai_runs%ROWTYPE;
  v_draft public.ai_data_entry_drafts%ROWTYPE;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0
    OR p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$' THEN
    RAISE EXCEPTION 'AI data-entry failure input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT event.* INTO v_event
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'ai.data_entry.requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  SELECT run.* INTO v_run
  FROM public.ai_runs AS run
  WHERE run.organization_id = v_event.organization_id
    AND run.id::text = v_event.payload ->> 'run_id'
    AND run.agent_kind = 'data_entry'
    AND run.status IN ('queued', 'running', 'failed')
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = v_event.organization_id
    AND draft.id::text = v_event.payload ->> 'draft_id'
    AND draft.ai_run_id = v_run.id
    AND draft.status IN ('queued', 'extracting', 'failed')
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_run.status <> 'failed' THEN
    UPDATE public.ai_runs
    SET status = 'failed',
        finished_at = timezone('utc', now()),
        error_code = p_error_code
    WHERE organization_id = v_run.organization_id AND id = v_run.id;
  END IF;

  IF v_draft.status <> 'failed' THEN
    UPDATE public.ai_data_entry_drafts
    SET status = 'failed',
        error_code = p_error_code,
        version = version + 1
    WHERE organization_id = v_draft.organization_id AND id = v_draft.id;
  END IF;

  -- Keep this explicit for idempotent failure retries; the terminal-status
  -- trigger enforces the same invariant on the first transition.
  UPDATE public.ai_data_entry_inputs AS input
  SET status = 'archived'
  WHERE input.organization_id = v_draft.organization_id
    AND input.draft_id = v_draft.id
    AND input.status = 'active';

  INSERT INTO public.notifications (
    organization_id, recipient_membership_id, category, title, body,
    resource_type, resource_id, dedupe_key
  ) VALUES (
    v_run.organization_id,
    v_run.initiated_by_membership_id,
    'system',
    'تعذر إكمال اقتراح AI',
    'تعذر تشغيل طلب الاقتراح. راجع الإعدادات أو أعد الطلب يدوياً.',
    'ai_run',
    v_run.id,
    'ai-run-failed:' || v_run.id::text || ':' || p_error_code
  ) ON CONFLICT (organization_id, dedupe_key) DO NOTHING;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.archive_terminal_ai_data_entry_inputs_v1() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.archive_ai_data_entry_inputs_v1(uuid,uuid,uuid[],uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.archive_ai_data_entry_inputs_v1(uuid,uuid,uuid[],uuid) TO service_role;

REVOKE ALL ON FUNCTION public.register_ai_data_entry_input_v1(uuid,uuid,text,text,bigint,text,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_ai_data_entry_input_v1(uuid,uuid,text,text,bigint,text,text,uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.finalize_ai_data_entry_failure_v1(uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_ai_data_entry_failure_v1(uuid,text,text) TO voya_outbox_worker, service_role;
