-- Close the final AI data-entry image boundary.
--
-- Manual property-image registration remains available through the public V1
-- command. AI-confirmed images use a service-only command bound to the exact
-- confirmation execution token. Property-image registration and intake mapping
-- happen in one PostgreSQL transaction, so any mapping failure rolls back the
-- source-of-record image row, audit event, and outbox event together.

CREATE OR REPLACE FUNCTION public.register_property_image_v1(
  p_organization_id uuid,
  p_property_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_width_px integer,
  p_height_px integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_idempotency_key LIKE 'ai-data-entry:%' THEN
    RAISE EXCEPTION 'AI property images require the trusted confirmation boundary' USING ERRCODE = '42501';
  END IF;

  RETURN public.register_property_image_without_ai_mapping_v1(
    p_organization_id,
    p_property_id,
    p_storage_path,
    p_mime_type,
    p_byte_size,
    p_width_px,
    p_height_px,
    p_idempotency_key,
    p_request_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.register_property_image_v1(uuid,uuid,text,text,bigint,integer,integer,text,uuid)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_property_image_v1(uuid,uuid,text,text,bigint,integer,integer,text,uuid)
TO authenticated;

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
  v_actor uuid;
  v_draft public.ai_data_entry_drafts%ROWTYPE;
  v_input public.ai_data_entry_inputs%ROWTYPE;
  v_existing public.property_images%ROWTYPE;
  v_image_id uuid;
  v_key_parts text[];
  v_property_index integer;
  v_property_payload jsonb;
  v_expected_prefix text;
  v_extension text;
  v_active_count integer;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_input_id IS NULL
    OR p_property_id IS NULL OR p_storage_path IS NULL OR p_mime_type IS NULL
    OR p_byte_size IS NULL OR p_execution_token IS NULL
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI property image application input is invalid' USING ERRCODE = '22023';
  END IF;

  v_key_parts := regexp_match(
    p_idempotency_key,
    '^ai-data-entry:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):property:([0-9]+):image:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
  );
  IF v_key_parts IS NULL
    OR v_key_parts[1]::uuid <> p_draft_id
    OR v_key_parts[3]::uuid <> p_input_id THEN
    RAISE EXCEPTION 'AI property image idempotency key is invalid' USING ERRCODE = '22023';
  END IF;
  v_property_index := v_key_parts[2]::integer;

  -- Same lock order as the other trusted confirmation helpers: draft, input,
  -- then property. Exact execution-token ownership prevents a stale execution
  -- from mutating under a replacement confirmation lease.
  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.id = p_draft_id
    AND draft.status = 'confirmed'
    AND draft.confirmation_execution_token = p_execution_token
  FOR UPDATE;
  IF NOT FOUND OR v_draft.confirmed_by_membership_id IS NULL THEN
    RAISE EXCEPTION 'AI property image confirmation claim is stale' USING ERRCODE = '40001';
  END IF;
  v_actor := v_draft.confirmed_by_membership_id;

  SELECT input.* INTO v_input
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = p_draft_id
    AND input.id = p_input_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI property image intake input is unavailable' USING ERRCODE = '40001';
  END IF;

  IF v_input.status = 'mapped' THEN
    IF v_input.mapped_property_id IS DISTINCT FROM p_property_id THEN
      RAISE EXCEPTION 'AI property image intake input is already mapped' USING ERRCODE = '40001';
    END IF;
    SELECT image.* INTO v_existing
    FROM public.property_images AS image
    WHERE image.organization_id = p_organization_id
      AND image.idempotency_key = btrim(p_idempotency_key)
      AND image.property_id = p_property_id
      AND image.status = 'active';
    IF FOUND
      AND v_existing.storage_path = p_storage_path
      AND v_existing.mime_type = p_mime_type
      AND v_existing.byte_size = p_byte_size
      AND v_existing.width_px IS NOT DISTINCT FROM p_width_px
      AND v_existing.height_px IS NOT DISTINCT FROM p_height_px THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'AI property image committed mapping is inconsistent' USING ERRCODE = '40001';
  END IF;
  IF v_input.status <> 'active' THEN
    RAISE EXCEPTION 'AI property image intake input is unavailable' USING ERRCODE = '40001';
  END IF;

  IF v_input.mime_type <> p_mime_type OR v_input.byte_size <> p_byte_size THEN
    RAISE EXCEPTION 'AI property image intake metadata changed' USING ERRCODE = '40001';
  END IF;

  IF jsonb_typeof(v_draft.confirmation_payload -> 'properties') <> 'array'
    OR v_property_index < 0
    OR v_property_index >= jsonb_array_length(v_draft.confirmation_payload -> 'properties') THEN
    RAISE EXCEPTION 'AI property image property selection is stale' USING ERRCODE = '40001';
  END IF;
  v_property_payload := v_draft.confirmation_payload -> 'properties' -> v_property_index;
  IF jsonb_typeof(v_property_payload -> 'imageInputIds') <> 'array'
    OR NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(v_property_payload -> 'imageInputIds') AS image_id(value)
      WHERE image_id.value = p_input_id::text
    ) THEN
    RAISE EXCEPTION 'AI property image was not confirmed for this property' USING ERRCODE = '40001';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(v_draft.application_result -> 'properties') = 'array'
          THEN v_draft.application_result -> 'properties'
        ELSE '[]'::jsonb
      END
    ) AS result(item)
    WHERE result.item ->> 'index' = v_property_index::text
      AND result.item ->> 'recordId' = p_property_id::text
  ) THEN
    RAISE EXCEPTION 'AI property image property record is not durable yet' USING ERRCODE = '40001';
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
      p_width_px, p_height_px, btrim(p_idempotency_key), v_actor
    )
    RETURNING id INTO v_image_id;

    INSERT INTO public.audit_events (
      organization_id, actor_type, actor_membership_id, action, resource_type,
      resource_id, outcome, request_id, after_delta
    ) VALUES (
      p_organization_id, 'user', v_actor, 'property.image_registered',
      'property_image', v_image_id, 'success', p_request_id,
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
  SET status = 'mapped',
      mapped_property_id = p_property_id,
      mapped_at = timezone('utc', now())
  WHERE organization_id = p_organization_id
    AND draft_id = p_draft_id
    AND id = p_input_id
    AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI property image intake mapping changed concurrently' USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.input.mapped',
    'ai_data_entry_input', p_input_id, 'success', p_request_id,
    jsonb_build_object('property_id', p_property_id, 'property_image_id', v_image_id)
  );

  RETURN v_image_id;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_ai_data_entry_property_image_v1(uuid,uuid,uuid,uuid,text,text,bigint,integer,integer,text,uuid,uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_ai_data_entry_property_image_v1(uuid,uuid,uuid,uuid,text,text,bigint,integer,integer,text,uuid,uuid)
TO service_role;
