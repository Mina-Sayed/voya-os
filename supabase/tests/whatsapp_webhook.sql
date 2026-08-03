-- Signed webhook ingestion is server-only, idempotent, and inbound-only.

DO $$
BEGIN
  IF has_function_privilege('anon', 'public.ingest_whatsapp_webhook_event(text,text,text,text,text,text,timestamptz)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.ingest_whatsapp_webhook_event(text,text,text,text,text,text,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'webhook ingestion must not be callable by browser roles';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.ingest_whatsapp_webhook_event(text,text,text,text,text,text,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service role must be able to invoke webhook ingestion';
  END IF;
END;
$$;

SET ROLE service_role;
SELECT public.ingest_whatsapp_webhook_event(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'webhook-thread-a', 'meta-event-a', '+201001234567',
  'رسالة واردة من اختبار ميتا', timezone('utc', now())
) AS first_message_id \gset

SELECT public.ingest_whatsapp_webhook_event(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'webhook-thread-a', 'meta-event-a', '+201001234567',
  'رسالة واردة من اختبار ميتا', timezone('utc', now())
);
RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.whatsapp_message_events WHERE event_key = 'meta-event-a' AND direction = 'inbound' AND delivery_status = 'received') <> 1 THEN
    RAISE EXCEPTION 'webhook event must be stored exactly once as inbound received';
  END IF;
  IF (SELECT count(*) FROM public.whatsapp_message_events WHERE event_key = 'meta-event-a' AND direction = 'outbound') <> 0 THEN
    RAISE EXCEPTION 'inbound webhook must not create an outbound message';
  END IF;
END;
$$;

SELECT 'WhatsApp webhook database integration tests passed' AS result;
