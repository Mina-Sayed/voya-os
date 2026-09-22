-- Base WhatsApp reads require a verified MFA session at the database boundary.
--
-- list_whatsapp_conversations_ai_v1 and the claim/finalize confirmation RPCs
-- were closed earlier; the three base reads below kept membership/role checks
-- only, so a password-only (aal1) JWT could read conversation metadata and
-- stored image paths directly through PostgREST. This suite proves the
-- database-owned AAL2 gate denies aal1 while an aal2 session keeps working,
-- and that the browser grant posture did not widen.

DO $$
BEGIN
  IF has_function_privilege('anon', 'public.list_whatsapp_conversations(uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.list_whatsapp_messages(uuid, uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.get_whatsapp_media_v1(uuid, uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.list_whatsapp_confirmation_media_v1(uuid, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'base WhatsApp reads must not be executable by anon';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.list_whatsapp_conversations(uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.list_whatsapp_messages(uuid, uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.get_whatsapp_media_v1(uuid, uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.list_whatsapp_confirmation_media_v1(uuid, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'base WhatsApp reads must remain executable by authenticated';
  END IF;
END;
$$;

-- Fixtures under the tenancy suite Tenant A (owner 11111111-...).
DO $$
DECLARE
  v_membership uuid;
BEGIN
  SELECT id INTO v_membership
  FROM public.organization_memberships
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND user_id = '11111111-1111-1111-1111-111111111111';

  INSERT INTO public.whatsapp_channels (
    id, organization_id, provider, external_channel_id, display_name,
    status, kill_switch, created_by_membership_id
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000701', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'meta_cloud', 'aal2-base-read-channel', 'AAL2 قناة', 'active', false, v_membership
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.whatsapp_conversations (
    id, organization_id, channel_id, external_conversation_key, status
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000702', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000701', 'aal2-base-read-conv', 'open'
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.whatsapp_message_events (
    id, organization_id, conversation_id, event_key, direction, body_text,
    delivery_status, message_type, provider_media_id, media_mime_hint,
    media_status, media_storage_bucket, media_storage_path, media_byte_size,
    media_checksum_sha256, media_stored_at
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000703', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000702', 'aal2-base-read-image', 'inbound',
    'صورة', 'received', 'image', 'prov-aal2-base-read', 'image/png', 'stored',
    'ai-intake',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/aaaaaaaa-0000-0000-0000-000000000702/aaaaaaaa-0000-0000-0000-000000000703.png',
    3, '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
    timezone('utc', now())
  ) ON CONFLICT (id) DO NOTHING;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal1', false);

DO $$
BEGIN
  BEGIN
    PERFORM public.list_whatsapp_conversations('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'AAL1 WhatsApp conversation reads must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    PERFORM public.list_whatsapp_messages(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000702'
    );
    RAISE EXCEPTION 'AAL1 WhatsApp message reads must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    PERFORM public.get_whatsapp_media_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000703'
    );
    RAISE EXCEPTION 'AAL1 WhatsApp media reads must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    PERFORM public.list_whatsapp_confirmation_media_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000702'
    );
    RAISE EXCEPTION 'AAL1 WhatsApp confirmation media reads must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

SELECT set_config('request.jwt.claim.aal', 'aal2', false);

DO $$
DECLARE
  v_conversations integer;
  v_messages integer;
  v_media integer;
  v_confirmation_media integer;
BEGIN
  SELECT count(*) INTO v_conversations
  FROM public.list_whatsapp_conversations('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  IF v_conversations < 1 THEN
    RAISE EXCEPTION 'AAL2 WhatsApp conversation reads must keep working';
  END IF;

  SELECT count(*) INTO v_messages
  FROM public.list_whatsapp_messages(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000702'
  );
  IF v_messages < 1 THEN
    RAISE EXCEPTION 'AAL2 WhatsApp message reads must keep working';
  END IF;

  SELECT count(*) INTO v_media
  FROM public.get_whatsapp_media_v1(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000703'
  );
  IF v_media <> 1 THEN
    RAISE EXCEPTION 'AAL2 WhatsApp media reads must keep working';
  END IF;

  SELECT count(*) INTO v_confirmation_media
  FROM public.list_whatsapp_confirmation_media_v1(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000702'
  );
  IF v_confirmation_media <> 1 THEN
    RAISE EXCEPTION 'AAL2 WhatsApp confirmation media reads must keep working';
  END IF;
END;
$$;

RESET ROLE;

SELECT 'WhatsApp base-read AAL2 database integration tests passed' AS result;
