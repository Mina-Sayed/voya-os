-- Voya OS V1 hardening: new bookings cannot target archived clients, and
-- webhook request bodies are bounded in the application route.

CREATE OR REPLACE FUNCTION public.reject_archived_booking_client()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.client_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.clients AS client_record
    WHERE client_record.organization_id = NEW.organization_id
      AND client_record.id = NEW.client_id
      AND client_record.archived_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'booking client is archived' USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reject_archived_booking_client() FROM PUBLIC;

DROP TRIGGER IF EXISTS bookings_reject_archived_client ON public.bookings;
CREATE TRIGGER bookings_reject_archived_client
  BEFORE INSERT OR UPDATE OF organization_id, client_id ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.reject_archived_booking_client();
