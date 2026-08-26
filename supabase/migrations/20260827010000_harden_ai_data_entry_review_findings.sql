-- Close the remaining PR #12 AI data-entry review findings at the database boundary.

CREATE OR REPLACE FUNCTION public.resolve_ai_data_entry_execution_v1(
  p_event_id uuid,
  p_worker_id text
)
RETURNS TABLE (
  run_id uuid, organization_id uuid, draft_id uuid, agent_kind text, purpose text,
  initiated_by_membership_id uuid, source_text text, inputs jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 THEN
    RAISE EXCEPTION 'worker AI data-entry context is invalid' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT run.id, run.organization_id, draft.id, run.agent_kind, run.purpose,
    run.initiated_by_membership_id, draft.source_text,
    coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', input.id,
        'storage_bucket', input.storage_bucket,
        'storage_path', input.storage_path,
        'mime_type', input.mime_type,
        'byte_size', input.byte_size
      ) ORDER BY input.created_at, input.id)
      FROM public.ai_data_entry_inputs AS input
      WHERE input.organization_id = draft.organization_id
        AND input.draft_id = draft.id
        AND input.status = 'active'
    ), '[]'::jsonb)
  FROM public.outbox_events AS event
  JOIN public.ai_runs AS run
    ON run.id::text = event.payload ->> 'run_id'
   AND run.organization_id = event.organization_id
  JOIN public.organization_memberships AS initiator
    ON initiator.organization_id = run.organization_id
   AND initiator.id = run.initiated_by_membership_id
   AND initiator.status = 'active'
   AND initiator.role IN ('owner', 'manager', 'sales_agent', 'operations')
  JOIN public.ai_data_entry_drafts AS draft
    ON draft.organization_id = event.organization_id
   AND draft.id::text = event.payload ->> 'draft_id'
  WHERE event.id = p_event_id
    AND event.event_type = 'ai.data_entry.requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND run.agent_kind = 'data_entry'
    AND run.status IN ('queued', 'running')
    AND draft.status IN ('queued', 'extracting');
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_ai_data_entry_execution_v1(uuid,text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_ai_data_entry_execution_v1(uuid,text)
TO voya_outbox_worker, service_role;

CREATE OR REPLACE FUNCTION public.get_ai_run_result_v1(
  p_organization_id uuid,
  p_run_id uuid
)
RETURNS TABLE (status text, result_summary jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_role text;
  v_actor uuid;
  v_agent_kind text;
BEGIN
  SELECT membership.role, membership.id
  INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';

  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'accountant') THEN
    RAISE EXCEPTION 'AI result read is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT run.status, run.result_summary, run.agent_kind
  INTO status, result_summary, v_agent_kind
  FROM public.ai_runs AS run
  WHERE run.organization_id = p_organization_id
    AND run.id = p_run_id
    AND (v_role IN ('owner', 'manager') OR run.initiated_by_membership_id = v_actor);

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_agent_kind = 'data_entry' THEN
    PERFORM public.require_ai_data_entry_aal2_v1();
  END IF;

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.get_ai_run_result_v1(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_ai_run_result_v1(uuid,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.apply_ai_data_entry_property_image_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_input_id uuid,
  p_property_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_width_px integer,
  p_height_px integer,
  p_idempotency_key text,
  p_execution_token uuid,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_draft public.ai_data_entry_drafts%ROWTYPE;
  v_input public.ai_data_entry_inputs%ROWTYPE;
  v_existing public.property_images%ROWTYPE;
  v_image_id uuid;
  v_expected_prefix text;
  v_expected_idempotency_key text;
  v_extension text;
  v_active_count integer;
  v_binding_count integer;
  v_property_index integer;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_input_id IS NULL
    OR p_property_id IS NULL OR p_storage_path IS NULL OR p_mime_type IS NULL
    OR p_byte_size IS NULL OR p_idempotency_key IS NULL
    OR char_length(btrim(p_idempotency_key)) = 0 OR p_execution_token IS NULL THEN
    RAISE EXCEPTION 'AI data-entry property image input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.id = p_draft_id
    AND draft.status = 'confirmed'
    AND draft.confirmation_execution_token = p_execution_token
    AND coalesce(draft.confirmation_execution_heartbeat_at, draft.confirmation_execution_claimed_at)
      > timezone('utc', now()) - interval '10 minutes'
  FOR UPDATE;
  IF NOT FOUND OR v_draft.confirmed_by_membership_id IS NULL THEN
    RAISE EXCEPTION 'AI data-entry image application claim is stale' USING ERRCODE = '40001';
  END IF;
  v_actor_membership_id := v_draft.confirmed_by_membership_id;

  SELECT count(*)::integer, min(binding.property_index)
  INTO v_binding_count, v_property_index
  FROM (
    SELECT (property_entry.ordinality - 1)::integer AS property_index
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(v_draft.confirmation_payload -> 'properties') = 'array'
          THEN v_draft.confirmation_payload -> 'properties'
        ELSE '[]'::jsonb
      END
    ) WITH ORDINALITY AS property_entry(value, ordinality)
    WHERE jsonb_typeof(property_entry.value -> 'imageInputIds') = 'array'
      AND (property_entry.value -> 'imageInputIds') ? p_input_id::text
  ) AS binding;

  IF v_binding_count <> 1 OR v_property_index IS NULL THEN
    RAISE EXCEPTION 'AI data-entry image was not confirmed for exactly one property' USING ERRCODE = '40001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(v_draft.application_result -> 'properties') = 'array'
          THEN v_draft.application_result -> 'properties'
        ELSE '[]'::jsonb
      END
    ) AS property_result(value)
    WHERE property_result.value ->> 'index' = v_property_index::text
      AND property_result.value ->> 'recordId' = p_property_id::text
  ) THEN
    RAISE EXCEPTION 'AI data-entry image property does not match the durable confirmed result' USING ERRCODE = '40001';
  END IF;

  v_expected_idempotency_key := 'ai-data-entry:' || p_draft_id::text
    || ':property:' || v_property_index::text || ':image:' || p_input_id::text;
  IF btrim(p_idempotency_key) <> v_expected_idempotency_key THEN
    RAISE EXCEPTION 'AI data-entry image idempotency binding is invalid' USING ERRCODE = '40001';
  END IF;

  SELECT input.* INTO v_input
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.id = p_input_id
    AND input.draft_id = p_draft_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI data-entry input was not found' USING ERRCODE = '23503';
  END IF;

  IF v_input.status = 'mapped' THEN
    IF v_input.mapped_property_id = p_property_id THEN
      SELECT image.id INTO v_image_id
      FROM public.property_images AS image
      WHERE image.organization_id = p_organization_id
        AND image.property_id = p_property_id
        AND image.idempotency_key = btrim(p_idempotency_key)
        AND image.status = 'active';
      IF v_image_id IS NOT NULL THEN RETURN v_image_id; END IF;
    END IF;
    RAISE EXCEPTION 'AI data-entry input is already mapped' USING ERRCODE = '40001';
  END IF;
  IF v_input.status <> 'active' THEN
    RAISE EXCEPTION 'AI data-entry input is unavailable' USING ERRCODE = '40001';
  END IF;
  IF v_input.storage_path IS NULL OR v_input.mime_type <> p_mime_type OR v_input.byte_size <> p_byte_size THEN
    RAISE EXCEPTION 'AI data-entry image metadata changed' USING ERRCODE = '40001';
  END IF;

  PERFORM 1
  FROM public.properties AS property_record
  WHERE property_record.organization_id = p_organization_id
    AND property_record.id = p_property_id
    AND property_record.status <> 'archived'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'property is not available for image registration' USING ERRCODE = '23503';
  END IF;

  v_expected_prefix := p_organization_id::text || '/' || p_property_id::text || '/';
  IF lower(p_storage_path) <> p_storage_path
    OR left(p_storage_path, char_length(v_expected_prefix)) <> v_expected_prefix
    OR p_storage_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'
    OR split_part(split_part(p_storage_path, '/', 3), '.', 1) <> p_input_id::text THEN
    RAISE EXCEPTION 'property image storage path is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_mime_type NOT IN ('image/jpeg', 'image/png', 'image/webp') THEN
    RAISE EXCEPTION 'property image mime type is invalid' USING ERRCODE = '22023';
  END IF;
  v_extension := lower(substring(p_storage_path FROM '[.]([a-z0-9]+)$'));
  IF (p_mime_type = 'image/jpeg' AND v_extension NOT IN ('jpg', 'jpeg'))
    OR (p_mime_type = 'image/png' AND v_extension <> 'png')
    OR (p_mime_type = 'image/webp' AND v_extension <> 'webp') THEN
    RAISE EXCEPTION 'property image mime type does not match its extension' USING ERRCODE = '22023';
  END IF;
  IF p_byte_size < 1 OR p_byte_size > 10485760 THEN
    RAISE EXCEPTION 'property image size is invalid' USING ERRCODE = '22023';
  END IF;
  IF (p_width_px IS NULL) <> (p_height_px IS NULL)
    OR (p_width_px IS NOT NULL AND (p_width_px < 1 OR p_width_px > 20000))
    OR (p_height_px IS NOT NULL AND (p_height_px < 1 OR p_height_px > 20000)) THEN
    RAISE EXCEPTION 'property image dimensions are invalid' USING ERRCODE = '22023';
  END IF;

  SELECT image.* INTO v_existing
  FROM public.property_images AS image
  WHERE image.organization_id = p_organization_id
    AND image.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.property_id = p_property_id
      AND v_existing.storage_path = p_storage_path
      AND v_existing.mime_type = p_mime_type
      AND v_existing.byte_size = p_byte_size
      AND v_existing.width_px IS NOT DISTINCT FROM p_width_px
      AND v_existing.height_px IS NOT DISTINCT FROM p_height_px
      AND v_existing.status = 'active' THEN
      v_image_id := v_existing.id;
    ELSE
      RAISE EXCEPTION 'idempotency key belongs to a different property image' USING ERRCODE = '23505';
    END IF;
  ELSE
    SELECT count(*)::integer INTO v_active_count
    FROM public.property_images AS image
    WHERE image.organization_id = p_organization_id
      AND image.property_id = p_property_id
      AND image.status = 'active';
    IF v_active_count >= 20 THEN
      RAISE EXCEPTION 'property image limit reached' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.property_images (
      organization_id, property_id, storage_path, mime_type, byte_size,
      width_px, height_px, idempotency_key, created_by_membership_id
    ) VALUES (
      p_organization_id, p_property_id, p_storage_path, p_mime_type, p_byte_size,
      p_width_px, p_height_px, btrim(p_idempotency_key), v_actor_membership_id
    ) RETURNING id INTO v_image_id;

    INSERT INTO public.audit_events (
      organization_id, actor_type, actor_membership_id, action, resource_type,
      resource_id, outcome, request_id, after_delta
    ) VALUES (
      p_organization_id, 'user', v_actor_membership_id,
      'property.image_registered', 'property_image', v_image_id, 'success',
      p_request_id,
      jsonb_build_object('property_id', p_property_id, 'mime_type', p_mime_type, 'storage_bucket', 'property-images')
    );
    INSERT INTO public.outbox_events (
      organization_id, event_type, schema_version, dedupe_key, payload
    ) VALUES (
      p_organization_id, 'property.image.registered', 1,
      'property-image-v1:' || v_image_id::text,
      jsonb_build_object('property_image_id', v_image_id, 'property_id', p_property_id, 'storage_path', p_storage_path)
    );
  END IF;

  UPDATE public.ai_data_entry_inputs
  SET status = 'mapped', mapped_property_id = p_property_id, mapped_at = timezone('utc', now())
  WHERE organization_id = p_organization_id
    AND id = p_input_id
    AND draft_id = p_draft_id
    AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI data-entry input mapping became stale' USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor_membership_id,
    'ai.data_entry.input.mapped', 'ai_data_entry_input', p_input_id, 'success',
    p_request_id,
    jsonb_build_object('property_id', p_property_id, 'property_image_id', v_image_id)
  );

  RETURN v_image_id;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_ai_data_entry_property_image_v1(uuid,uuid,uuid,uuid,text,text,bigint,integer,integer,text,uuid,uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_ai_data_entry_property_image_v1(uuid,uuid,uuid,uuid,text,text,bigint,integer,integer,text,uuid,uuid)
TO service_role;
