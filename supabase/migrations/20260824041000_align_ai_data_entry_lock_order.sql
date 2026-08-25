-- Keep every trusted confirmation/input lifecycle helper on one lock order:
-- ai_data_entry_drafts first, then ai_data_entry_inputs.

CREATE OR REPLACE FUNCTION public.mark_ai_data_entry_input_mapped_v2(
  p_organization_id uuid,
  p_input_id uuid,
  p_property_id uuid,
  p_property_image_id uuid,
  p_execution_token uuid,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_input public.ai_data_entry_inputs%ROWTYPE;
  v_actor uuid;
  v_draft_id uuid;
BEGIN
  IF p_organization_id IS NULL OR p_input_id IS NULL OR p_property_id IS NULL
    OR p_property_image_id IS NULL OR p_execution_token IS NULL THEN
    RAISE EXCEPTION 'AI data-entry trusted image mapping input is invalid' USING ERRCODE = '22023';
  END IF;

  -- Resolve and lock the owning draft in a single statement. The EXISTS probe
  -- does not lock the input; the input row is locked only after this draft lock.
  SELECT draft.confirmed_by_membership_id, draft.id
    INTO v_actor, v_draft_id
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.status = 'confirmed'
    AND draft.confirmation_execution_token = p_execution_token
    AND EXISTS (
      SELECT 1
      FROM public.ai_data_entry_inputs AS candidate
      WHERE candidate.organization_id = p_organization_id
        AND candidate.id = p_input_id
        AND candidate.draft_id = draft.id
    )
  FOR UPDATE;
  IF NOT FOUND OR v_actor IS NULL THEN
    RAISE EXCEPTION 'AI data-entry image mapping claim is stale' USING ERRCODE = '40001';
  END IF;

  SELECT input.* INTO v_input
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.id = p_input_id
    AND input.draft_id = v_draft_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI data-entry image mapping claim is stale' USING ERRCODE = '40001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.property_images AS image
    WHERE image.organization_id = p_organization_id
      AND image.id = p_property_image_id
      AND image.property_id = p_property_id
      AND image.status = 'active'
  ) THEN
    RAISE EXCEPTION 'registered property image is missing' USING ERRCODE = '23503';
  END IF;

  IF v_input.status = 'mapped' THEN
    IF v_input.mapped_property_id = p_property_id THEN RETURN true; END IF;
    RAISE EXCEPTION 'AI data-entry input is already mapped' USING ERRCODE = '40001';
  END IF;
  IF v_input.status <> 'active' THEN
    RAISE EXCEPTION 'AI data-entry input is unavailable' USING ERRCODE = '40001';
  END IF;

  UPDATE public.ai_data_entry_inputs
  SET status = 'mapped',
      mapped_property_id = p_property_id,
      mapped_at = timezone('utc', now())
  WHERE organization_id = p_organization_id
    AND id = p_input_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.input.mapped',
    'ai_data_entry_input', p_input_id, 'success', p_request_id,
    jsonb_build_object('property_id', p_property_id, 'property_image_id', p_property_image_id)
  );
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_ai_data_entry_input_mapped_v2(uuid,uuid,uuid,uuid,uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_ai_data_entry_input_mapped_v2(uuid,uuid,uuid,uuid,uuid,uuid) TO service_role;
