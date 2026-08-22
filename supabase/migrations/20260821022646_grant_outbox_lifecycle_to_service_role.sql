-- The Edge Function uses a service-role Supabase client while the database
-- lifecycle functions were originally granted only to the dedicated worker role.
GRANT EXECUTE ON FUNCTION public.complete_outbox_event(uuid, text),
  public.fail_outbox_event(uuid, text, text, integer, integer),
  public.purge_outbox_events(integer, integer)
TO service_role;
