-- Keep V1's table return contract stable; add worker-only provider route context in V2.
CREATE FUNCTION public.resolve_whatsapp_ai_execution_v2(
  p_event_id uuid,
  p_worker_id text
)
RETURNS TABLE (
  run_id uuid,
  organization_id uuid,
  conversation_id uuid,
  message_id uuid,
  provider text,
  phone_number_id text,
  provider_channel_id text,
  chat_id text,
  recipient_phone text,
  conversation_status text,
  ai_enabled boolean,
  conversation_type text,
  structured_state jsonb,
  source_message jsonb,
  recent_messages jsonb,
  linked_lead jsonb,
  linked_client jsonb,
  linked_owner jsonb,
  should_process boolean,
  skip_reason text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT context.run_id,
         context.organization_id,
         context.conversation_id,
         context.message_id,
         context.provider,
         context.phone_number_id,
         context.phone_number_id,
         conversation.external_conversation_key,
         context.recipient_phone,
         context.conversation_status,
         context.ai_enabled,
         context.conversation_type,
         context.structured_state,
         context.source_message,
         context.recent_messages,
         context.linked_lead,
         context.linked_client,
         context.linked_owner,
         context.should_process,
         context.skip_reason
  FROM public.resolve_whatsapp_ai_execution_v1(p_event_id, p_worker_id) AS context
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.organization_id = context.organization_id
   AND conversation.id = context.conversation_id;
$$;

REVOKE ALL ON FUNCTION public.resolve_whatsapp_ai_execution_v2(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_whatsapp_ai_execution_v2(uuid, text) TO voya_outbox_worker, service_role;
