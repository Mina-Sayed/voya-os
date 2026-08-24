-- Apply a confirmed AI intake image through the trusted service boundary.
-- The execution token is mandatory so a reclaimed/stale worker cannot mutate
-- property-image source records under a different live confirmation claim.

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
  v_input public.ai_data_entry_inputs%ROWTYPE;
  v_existing public.property_images%ROWTYPE;
  v_image_id uuid;
  v_expected_prefix text;
  v_extension text;
  v_active_count integer;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_input_id IS NULL
    OR p_property_id IS NULL OR p_storage_path IS NULL OR p_mime_type IS NULL
    OR p_byte_size IS NULL OR p_idempotency_key IS NULL
    OR char_length(btrim(p_idempotency_key)) = 0 OR p_execution_token IS NULL THEN
    RAISE EXCEPTION 'AI data-entry property image input is invalid' USING ERRCODE = '22023';
  END IF;

  -- Lock order is draft -> input -> property. The exact token, not merely a
  -- fresh claim by the same actor, owns this source-record mutation.
  SELECT draft.confirmed_by_membership_id INTO v_actor_membership_id
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.id = p_draft_id
    AND draft.status = 'confirmed'
    AND draft.confirmation_execution_token = p_execution_token
    AND coalesce(draft.confirmation_execution_heartbeat_at, draft.confirmation_execution_claimed_at)
      > timezone('utc', now()) - interval '10 minutes'
  FOR UPDATE;
  IF NOT FOUND OR v_actor_membership_id IS NULL THEN
    RAISE EXCEPTION 'AI data-entry image application claim is stale' USING ERRCODE = '40001';
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
  WHERE organization_id = p_organization_id AND id = p_input_id AND draft_id = p_draft_id AND status = 'active';
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
