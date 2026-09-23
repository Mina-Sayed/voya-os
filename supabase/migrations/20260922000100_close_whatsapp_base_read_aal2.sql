-- Close the MFA AAL2 gap on the base WhatsApp reads.
--
-- list_whatsapp_conversations_ai_v1, claim/finalize WhatsApp property
-- confirmation, and the booking commercial paths already require a verified
-- MFA session at the database boundary through require_workspace_aal2_v1().
-- The three base reads below kept membership/role checks only, so a
-- password-only (aal1) JWT could read conversation metadata and stored
-- image paths directly through PostgREST. This migration adds the same
-- database-owned gate; bodies are otherwise unchanged and existing
-- EXECUTE grants are preserved by CREATE OR REPLACE.
--
-- The staff media preview route calls get_whatsapp_media_v1 with the
-- caller's user JWT only after loadActionWorkspaceMembership resolves,
-- which itself requires a satisfied MFA session, so the gated route
-- keeps working while direct aal1 RPC calls are denied.

CREATE OR REPLACE FUNCTION public.list_whatsapp_conversations(p_organization_id uuid)
RETURNS TABLE (
  id uuid,
  channel_id uuid,
  channel_name text,
  contact_label text,
  status text,
  assigned_membership_id uuid,
  last_message_at timestamptz,
  last_message_preview text,
  last_message_direction text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_role text;
  v_actor uuid;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RAISE EXCEPTION 'conversation read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT conversation.id,
         conversation.channel_id,
         channel.display_name,
         coalesce(contact.display_value, client_record.display_name, lead_record.title, 'جهة اتصال غير معروفة'),
         conversation.status,
         conversation.assigned_membership_id,
         latest.created_at,
         latest.body_text,
         latest.direction
  FROM public.whatsapp_conversations AS conversation
  JOIN public.whatsapp_channels AS channel
    ON channel.id = conversation.channel_id
   AND channel.organization_id = conversation.organization_id
  LEFT JOIN public.crm_contact_methods AS contact
    ON contact.id = conversation.contact_method_id
   AND contact.organization_id = conversation.organization_id
  LEFT JOIN public.clients AS client_record
    ON client_record.id = conversation.client_id
   AND client_record.organization_id = conversation.organization_id
  LEFT JOIN public.leads AS lead_record
    ON lead_record.id = conversation.lead_id
   AND lead_record.organization_id = conversation.organization_id
  LEFT JOIN LATERAL (
    SELECT message.created_at, message.body_text, message.direction
    FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = conversation.organization_id
      AND message.conversation_id = conversation.id
    ORDER BY message.created_at DESC, message.id DESC
    LIMIT 1
  ) AS latest ON true
  WHERE conversation.organization_id = p_organization_id
    AND (v_role IN ('owner', 'manager') OR conversation.assigned_membership_id IS NULL OR conversation.assigned_membership_id = v_actor)
  ORDER BY conversation.last_message_at DESC NULLS LAST, conversation.created_at DESC, conversation.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_whatsapp_messages(
  p_organization_id uuid,
  p_conversation_id uuid
)
RETURNS TABLE (
  id uuid,
  direction text,
  body_text text,
  delivery_status text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RAISE EXCEPTION 'message read is not permitted' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.whatsapp_conversations AS conversation
    WHERE conversation.id = p_conversation_id AND conversation.organization_id = p_organization_id
      AND (v_role IN ('owner', 'manager') OR conversation.assigned_membership_id IS NULL OR conversation.assigned_membership_id = v_actor)
  ) THEN RAISE EXCEPTION 'conversation is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY
  SELECT message.id, message.direction, message.body_text, message.delivery_status, message.created_at
  FROM public.whatsapp_message_events AS message
  WHERE message.organization_id = p_organization_id AND message.conversation_id = p_conversation_id
  ORDER BY message.created_at ASC, message.id ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_whatsapp_media_v1(
  p_organization_id uuid,
  p_message_id uuid
)
RETURNS TABLE (
  message_id uuid,
  conversation_id uuid,
  storage_bucket text,
  storage_path text,
  mime_type text,
  byte_size bigint,
  media_status text,
  caption text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RAISE EXCEPTION 'WhatsApp media read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT message.id, message.conversation_id, message.media_storage_bucket,
         message.media_storage_path, message.media_mime_hint, message.media_byte_size,
         message.media_status, message.caption
  FROM public.whatsapp_message_events AS message
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.organization_id = message.organization_id
   AND conversation.id = message.conversation_id
  WHERE message.organization_id = p_organization_id
    AND message.id = p_message_id
    AND message.message_type = 'image'
    AND message.media_status = 'stored'
    AND (v_role IN ('owner', 'manager') OR conversation.assigned_membership_id IS NULL OR conversation.assigned_membership_id = v_actor);
END;
$$;
