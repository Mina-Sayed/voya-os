-- Do not enqueue an AI provider call for whitespace-only text without images.
-- Image-only drafts remain valid because they have active input metadata.

CREATE OR REPLACE FUNCTION public.submit_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_source_text text;
  v_has_active_input boolean;
BEGIN
  PERFORM public.require_ai_data_entry_aal2_v1();

  SELECT draft.source_text,
         EXISTS (
           SELECT 1
           FROM public.ai_data_entry_inputs AS input
           WHERE input.organization_id = draft.organization_id
             AND input.draft_id = draft.id
             AND input.status = 'active'
         )
    INTO v_source_text, v_has_active_input
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.id = p_draft_id;

  IF FOUND AND char_length(btrim(coalesce(v_source_text, ''), E' \t\n\r')) = 0 AND NOT v_has_active_input THEN
    RAISE EXCEPTION 'AI data-entry draft has no source content' USING ERRCODE = '22023';
  END IF;

  RETURN public.submit_ai_data_entry_draft_without_aal2_v1(
    p_organization_id, p_draft_id, p_idempotency_key, p_request_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.submit_ai_data_entry_draft_v1(uuid,uuid,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_ai_data_entry_draft_v1(uuid,uuid,text,uuid) TO authenticated;
