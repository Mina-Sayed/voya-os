-- Do not send an expired queued data-entry draft to the provider.
-- The worker failure path will terminalize the run/draft and the terminal
-- trigger archives any remaining active intake metadata before review.

CREATE OR REPLACE FUNCTION public.mark_ai_data_entry_extracting_v1(
  p_event_id uuid,
  p_worker_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_draft_id uuid;
  v_organization_id uuid;
  v_status text;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 THEN
    RAISE EXCEPTION 'AI data-entry extraction claim is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT draft.id, draft.organization_id, draft.status
    INTO v_draft_id, v_organization_id, v_status
  FROM public.outbox_events AS event
  JOIN public.ai_data_entry_drafts AS draft
    ON draft.organization_id = event.organization_id
   AND draft.id::text = event.payload ->> 'draft_id'
  WHERE event.id = p_event_id
    AND event.event_type = 'ai.data_entry.requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND draft.status IN ('queued', 'extracting')
    AND draft.expires_at > timezone('utc', now())
  FOR UPDATE OF draft;

  IF NOT FOUND THEN RETURN false; END IF;
  IF v_status = 'extracting' THEN RETURN true; END IF;

  UPDATE public.ai_data_entry_drafts
  SET status = 'extracting', version = version + 1, error_code = NULL
  WHERE organization_id = v_organization_id AND id = v_draft_id AND status = 'queued'
    AND expires_at > timezone('utc', now());
  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_ai_data_entry_extracting_v1(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_ai_data_entry_extracting_v1(uuid,text) TO voya_outbox_worker, service_role;
