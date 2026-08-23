-- The Edge Function uses a service-role Supabase client while the database
-- lifecycle functions were originally granted only to the dedicated worker role.
GRANT EXECUTE ON FUNCTION public.complete_outbox_event(uuid, text),
  public.fail_outbox_event(uuid, text, text, integer, integer),
  public.purge_outbox_events(integer, integer)
TO service_role;

-- Provider delivery can occur late in a claimed batch. Revalidate and extend
-- the still-live worker lease immediately before sending email or WhatsApp so
-- a reclaimed event cannot be delivered by both the stale and replacement
-- workers. This deliberately does not revive an expired lease.
CREATE OR REPLACE FUNCTION public.renew_outbox_delivery_lease_v1(
  p_event_id uuid,
  p_worker_id text,
  p_lease_seconds integer DEFAULT 300
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_count integer;
BEGIN
  IF p_event_id IS NULL
    OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120
    OR p_lease_seconds IS NULL OR p_lease_seconds < 1 OR p_lease_seconds > 900 THEN
    RAISE EXCEPTION 'outbox delivery lease renewal input is invalid' USING ERRCODE = '22023';
  END IF;

  UPDATE public.outbox_events AS event
  SET locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds)
  WHERE event.id = p_event_id
    AND event.event_type IN (
      'organization.invitation.send_requested',
      'member.invitation.resent',
      'whatsapp.message.send_requested'
    )
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now());
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.renew_outbox_delivery_lease_v1(uuid,text,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.renew_outbox_delivery_lease_v1(uuid,text,integer) TO voya_outbox_worker, service_role;
