-- Close the MFA AAL2 gap on the WhatsApp confirmation-media read.
--
-- list_whatsapp_confirmation_media_v1 arrived with membership/role
-- checks only, while its claim/finalize siblings and the base WhatsApp
-- reads require a verified MFA session at the database boundary through
-- require_workspace_aal2_v1(). An aal1 JWT could otherwise read stored
-- image paths directly through PostgREST. Body unchanged apart from the
-- gate; existing EXECUTE grants are preserved by CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION public.list_whatsapp_confirmation_media_v1(
  p_organization_id uuid,
  p_conversation_id uuid
)
RETURNS TABLE (
  id uuid,
  message_type text,
  media_status text,
  media_storage_bucket text,
  media_storage_path text,
  media_mime_hint text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_role text;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_organization_id IS NULL OR p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'WhatsApp confirmation media input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.role
    INTO v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';

  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'operations') THEN
    RAISE EXCEPTION 'WhatsApp confirmation media read is not permitted' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.whatsapp_conversations AS conversation
    WHERE conversation.id = p_conversation_id
      AND conversation.organization_id = p_organization_id
  ) THEN
    RAISE EXCEPTION 'WhatsApp conversation is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    message.id,
    message.message_type,
    message.media_status,
    message.media_storage_bucket,
    message.media_storage_path,
    message.media_mime_hint
  FROM public.whatsapp_message_events AS message
  WHERE message.organization_id = p_organization_id
    AND message.conversation_id = p_conversation_id
    AND message.message_type = 'image'
    AND message.media_status = 'stored'
  ORDER BY message.created_at ASC, message.id ASC;
END;
$$;
