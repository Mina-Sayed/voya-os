-- Project terminal media jobs without changing message storage state or retrying delivery.
CREATE INDEX outbox_whatsapp_media_review_message_idx
  ON public.outbox_events (organization_id, (payload->>'message_id'))
  WHERE event_type = 'whatsapp.media.store_requested' AND state IN ('needs_review', 'dead_letter');

CREATE OR REPLACE FUNCTION public.list_whatsapp_conversations_ai_v1_without_workspace_aal2(
  p_organization_id uuid
)
RETURNS TABLE (
  id uuid,
  channel_id uuid,
  channel_name text,
  contact_label text,
  status text,
  assigned_membership_id uuid,
  last_message_at timestamptz,
  last_message_preview text,
  last_message_direction text,
  ai_enabled boolean,
  conversation_type text,
  lead_id uuid,
  client_id uuid,
  property_owner_id uuid,
  property_id uuid,
  structured_state jsonb,
  last_customer_message_at timestamptz,
  last_ai_message_at timestamptz,
  next_follow_up_at timestamptz,
  ai_state_version integer,
  recent_messages jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RAISE EXCEPTION 'conversation AI read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT conversation.id,
         conversation.channel_id,
         channel.display_name,
         coalesce(contact.display_value, client_record.display_name, lead_record.title, 'جهة اتصال غير معروفة'),
         conversation.status,
         conversation.assigned_membership_id,
         latest.created_at,
         CASE WHEN latest.message_type = 'image' THEN coalesce(latest.caption, 'صورة مرفقة') ELSE latest.body_text END,
         latest.direction,
         conversation.ai_enabled,
         conversation.conversation_type,
         conversation.lead_id,
         conversation.client_id,
         conversation.property_owner_id,
         conversation.property_id,
         conversation.structured_state,
         conversation.last_customer_message_at,
         conversation.last_ai_message_at,
         conversation.next_follow_up_at,
         conversation.ai_state_version,
         coalesce((
           SELECT jsonb_agg(
             jsonb_build_object(
               'id', recent.id,
               'direction', recent.direction,
               'message_type', recent.message_type,
               'body_text', left(recent.body_text, 2000),
               'caption', recent.caption,
               'delivery_status', recent.delivery_status,
               'media_status', CASE
                 WHEN recent.media_status = 'pending' AND EXISTS (
                   SELECT 1 FROM public.outbox_events AS event
                   WHERE event.organization_id = conversation.organization_id
                     AND event.event_type = 'whatsapp.media.store_requested'
                     AND event.state IN ('needs_review', 'dead_letter')
                     AND event.payload->>'message_id' = recent.id::text
                 ) THEN 'needs_review'
                 ELSE recent.media_status
               END,
               'media_mime_hint', recent.media_mime_hint,
               'media_byte_size', recent.media_byte_size,
               'media_checksum_sha256', recent.media_checksum_sha256,
               'media_storage_bucket', recent.media_storage_bucket,
               'media_storage_path', recent.media_storage_path,
               'created_at', recent.created_at
             ) ORDER BY recent.created_at ASC, recent.id ASC
           )
           FROM (
             SELECT message.id, message.direction, message.message_type,
                    message.body_text, message.caption, message.delivery_status,
                    message.media_status, message.media_mime_hint,
                    message.media_byte_size, message.media_checksum_sha256,
                    message.media_storage_bucket, message.media_storage_path,
                    message.created_at
             FROM public.whatsapp_message_events AS message
             WHERE message.organization_id = conversation.organization_id
               AND message.conversation_id = conversation.id
             ORDER BY message.created_at DESC, message.id DESC
             LIMIT 20
           ) AS recent
         ), '[]'::jsonb)
  FROM public.whatsapp_conversations AS conversation
  JOIN public.whatsapp_channels AS channel
    ON channel.organization_id = conversation.organization_id
   AND channel.id = conversation.channel_id
  LEFT JOIN public.crm_contact_methods AS contact
    ON contact.organization_id = conversation.organization_id
   AND contact.id = conversation.contact_method_id
  LEFT JOIN public.leads AS lead_record
    ON lead_record.organization_id = conversation.organization_id
   AND lead_record.id = conversation.lead_id
  LEFT JOIN public.clients AS client_record
    ON client_record.organization_id = conversation.organization_id
   AND client_record.id = conversation.client_id
  LEFT JOIN LATERAL (
    SELECT message.created_at, message.message_type, message.caption, message.body_text, message.direction
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

REVOKE ALL ON FUNCTION public.list_whatsapp_conversations_ai_v1_without_workspace_aal2(uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.get_whatsapp_media_health_v1(p_organization_id uuid)
RETURNS TABLE (media_review_count bigint, oldest_media_review_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
      AND membership.status = 'active' AND membership.role IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'WhatsApp media health read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT count(*), min(event.created_at)
  FROM public.outbox_events AS event
  WHERE event.organization_id = p_organization_id
    AND event.event_type = 'whatsapp.media.store_requested'
    AND event.state IN ('needs_review', 'dead_letter');
END;
$$;
REVOKE ALL ON FUNCTION public.get_whatsapp_media_health_v1(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_whatsapp_media_health_v1(uuid) TO authenticated;
