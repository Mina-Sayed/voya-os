-- Terminal privacy invariant: whenever a data-entry draft becomes expired or
-- rejected, no active intake metadata may remain reachable. Storage object
-- deletion is still performed by the trusted application/worker cleanup path;
-- this trigger makes the metadata lifecycle atomic with the terminal state.

CREATE OR REPLACE FUNCTION public.archive_ai_data_entry_inputs_on_terminal_status()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.status IN ('expired', 'rejected')
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

DROP TRIGGER IF EXISTS trg_ai_data_entry_terminal_input_archival ON public.ai_data_entry_drafts;
CREATE TRIGGER trg_ai_data_entry_terminal_input_archival
AFTER UPDATE OF status ON public.ai_data_entry_drafts
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status AND NEW.status IN ('expired', 'rejected'))
EXECUTE FUNCTION public.archive_ai_data_entry_inputs_on_terminal_status();

REVOKE ALL ON FUNCTION public.archive_ai_data_entry_inputs_on_terminal_status() FROM PUBLIC, anon, authenticated;
