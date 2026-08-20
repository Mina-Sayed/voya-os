-- Voya OS V1: one controlled outbox delivery boundary.
-- Provider calls remain in the Supabase Edge Function. The database exposes
-- only lease-owned worker RPCs and never grants browser roles direct access.

ALTER TABLE public.outbox_events
  DROP CONSTRAINT IF EXISTS outbox_events_state_check;

ALTER TABLE public.outbox_events
  ADD CONSTRAINT outbox_events_state_check
  CHECK (state IN ('pending', 'processing', 'retry_wait', 'completed', 'dead_letter', 'needs_review'));

CREATE INDEX IF NOT EXISTS outbox_events_review_idx
  ON public.outbox_events (updated_at DESC)
  WHERE state = 'needs_review';

ALTER TABLE public.whatsapp_message_events
  ADD COLUMN IF NOT EXISTS provider_message_id text,
  ADD COLUMN IF NOT EXISTS sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS delivered_at timestamptz,
  ADD COLUMN IF NOT EXISTS read_at timestamptz,
  ADD COLUMN IF NOT EXISTS failed_at timestamptz,
  ADD COLUMN IF NOT EXISTS provider_error_code text;

CREATE OR REPLACE FUNCTION public.claim_outbox_delivery_events(
  p_worker_id text,
  p_limit integer,
  p_lease_seconds integer
)
RETURNS SETOF public.outbox_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120 THEN
    RAISE EXCEPTION 'worker id is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 20 THEN
    RAISE EXCEPTION 'delivery batch must be between 1 and 20' USING ERRCODE = '22023';
  END IF;
  IF p_lease_seconds IS NULL OR p_lease_seconds < 1 OR p_lease_seconds > 900 THEN
    RAISE EXCEPTION 'lease duration must be between 1 and 900 seconds' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH eligible AS (
    SELECT event.id
    FROM public.outbox_events AS event
    WHERE event.event_type IN (
      'organization.invitation.send_requested',
      'member.invitation.resent',
      'whatsapp.message.send_requested'
    )
      AND (
        (event.state IN ('pending', 'retry_wait') AND event.available_at <= timezone('utc', now()))
        OR (event.state = 'processing' AND event.locked_until <= timezone('utc', now()))
      )
    ORDER BY
      CASE WHEN event.state = 'processing' THEN event.locked_until ELSE event.available_at END ASC,
      event.created_at ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.outbox_events AS event
  SET state = 'processing',
      attempts = event.attempts + 1,
      locked_by = p_worker_id,
      locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds),
      last_error_code = NULL
  FROM eligible
  WHERE event.id = eligible.id
  RETURNING event.*;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_outbox_event_needs_review(
  p_event_id uuid,
  p_worker_id text,
  p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE updated_count integer;
BEGIN
  IF p_event_id IS NULL THEN RAISE EXCEPTION 'event id is required' USING ERRCODE = '22023'; END IF;
  IF p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120 THEN
    RAISE EXCEPTION 'worker id is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$' THEN
    RAISE EXCEPTION 'error code must be a short safe identifier' USING ERRCODE = '22023';
  END IF;

  UPDATE public.outbox_events
  SET state = 'needs_review',
      locked_by = NULL,
      locked_until = NULL,
      last_error_code = p_error_code
  WHERE id = p_event_id
    AND state = 'processing'
    AND locked_by = p_worker_id
    AND locked_until > timezone('utc', now());
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count = 1;
END;
$$;

-- The compatibility RPC remains available to old callers, but it no longer
-- persists a raw invitation token in the outbox. The V1 server action uses
-- invite_organization_member_v1 and supplies an encrypted delivery payload.
CREATE OR REPLACE FUNCTION public.invite_organization_member_v1(
  p_organization_id uuid,
  p_email text,
  p_role text,
  p_token_digest text,
  p_sealed_token text DEFAULT NULL,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_invitation_id uuid;
  v_email text := lower(btrim(p_email));
  v_role text := lower(btrim(p_role));
  v_token_digest text;
  v_expires_at timestamptz := timezone('utc', now()) + interval '72 hours';
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role = 'owner';
  IF v_actor IS NULL THEN RAISE EXCEPTION 'member invitation is not permitted' USING ERRCODE = '42501'; END IF;
  IF v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    OR v_role NOT IN ('owner', 'manager', 'operator', 'viewer')
    OR p_token_digest IS NULL OR p_token_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invitation input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_sealed_token IS NOT NULL AND (
    char_length(p_sealed_token) NOT BETWEEN 20 AND 4096
    OR p_sealed_token !~ '^v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'
  ) THEN
    RAISE EXCEPTION 'sealed invitation payload is invalid' USING ERRCODE = '22023';
  END IF;

  v_token_digest := encode(extensions.digest(p_token_digest, 'sha256'), 'hex');
  IF EXISTS (
    SELECT 1
    FROM public.organization_memberships AS membership
    JOIN auth.users AS account ON account.id = membership.user_id
    WHERE membership.organization_id = p_organization_id
      AND lower(account.email) = v_email
      AND membership.status = 'active'
  ) THEN
    RAISE EXCEPTION 'user is already a member' USING ERRCODE = '23505';
  END IF;

  UPDATE public.organization_invitations
  SET status = 'revoked', updated_at = timezone('utc', now())
  WHERE organization_id = p_organization_id AND normalized_email = v_email AND status = 'pending';

  INSERT INTO public.organization_invitations (
    organization_id, normalized_email, role, token_digest, expires_at, created_by_membership_id
  ) VALUES (
    p_organization_id, v_email, v_role, v_token_digest, v_expires_at, v_actor
  ) RETURNING id INTO v_invitation_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'member.invited', 'organization_invitation',
    v_invitation_id, 'success', p_request_id, jsonb_build_object('email', v_email, 'role', v_role)
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id,
    'organization.invitation.send_requested',
    1,
    'organization-invitation:' || v_invitation_id::text,
    jsonb_build_object(
      'invitation_id', v_invitation_id,
      'email', v_email,
      'role', v_role,
      'sealed_token', p_sealed_token,
      'expires_at', v_expires_at
    )
  );
  RETURN v_invitation_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.invite_organization_member(
  p_organization_id uuid,
  p_email text,
  p_role text,
  p_token_digest text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  RETURN public.invite_organization_member_v1(
    p_organization_id, p_email, p_role, p_token_digest, NULL, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.resend_organization_invitation_v1(
  p_organization_id uuid,
  p_invitation_id uuid,
  p_token_digest text,
  p_sealed_token text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_invitation public.organization_invitations%ROWTYPE;
  v_expires_at timestamptz := timezone('utc', now()) + interval '72 hours';
  v_dedupe_key text := 'invitation-resend:' || p_invitation_id::text || ':' || coalesce(p_request_id::text, extensions.gen_random_uuid()::text);
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role = 'owner';
  IF v_actor IS NULL THEN RAISE EXCEPTION 'invitation resend is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_token_digest IS NULL OR p_token_digest !~ '^[0-9a-f]{64}$'
    OR p_sealed_token IS NULL OR char_length(p_sealed_token) NOT BETWEEN 20 AND 4096
    OR p_sealed_token !~ '^v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION 'invitation resend payload is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT invitation.* INTO v_invitation
  FROM public.organization_invitations AS invitation
  WHERE invitation.id = p_invitation_id
    AND invitation.organization_id = p_organization_id
    AND invitation.status = 'pending'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pending invitation is invalid' USING ERRCODE = '23503'; END IF;

  UPDATE public.organization_invitations
  SET token_digest = encode(extensions.digest(p_token_digest, 'sha256'), 'hex'),
      expires_at = v_expires_at,
      delivery_status = 'pending',
      updated_at = timezone('utc', now())
  WHERE id = v_invitation.id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id
  ) VALUES (
    p_organization_id, 'user', v_actor, 'member.invitation_resent',
    'organization_invitation', p_invitation_id, 'success', p_request_id
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id, 'member.invitation.resent', 1, v_dedupe_key,
    jsonb_build_object(
      'invitation_id', p_invitation_id,
      'email', v_invitation.normalized_email,
      'role', v_invitation.role,
      'sealed_token', p_sealed_token,
      'expires_at', v_expires_at
    )
  );
  RETURN true;
END;
$$;

-- Worker-owned delivery context for WhatsApp. The provider destination is
-- derived from tenant data; it is never accepted from the browser payload.
CREATE OR REPLACE FUNCTION public.resolve_whatsapp_outbox_delivery(
  p_event_id uuid,
  p_worker_id text
)
RETURNS TABLE (phone_number_id text, recipient_phone text, body_text text, message_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 THEN
    RAISE EXCEPTION 'worker delivery context is invalid' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT channel.external_channel_id,
         contact.normalized_value,
         message.body_text,
         message.id
  FROM public.outbox_events AS event
  JOIN public.whatsapp_message_events AS message
    ON message.id = (event.payload ->> 'message_id')::uuid
   AND message.organization_id = event.organization_id
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.id = message.conversation_id
   AND conversation.organization_id = event.organization_id
  JOIN public.whatsapp_channels AS channel
    ON channel.id = conversation.channel_id
   AND channel.organization_id = event.organization_id
  JOIN public.crm_contact_methods AS contact
    ON contact.id = conversation.contact_method_id
   AND contact.organization_id = event.organization_id
   AND contact.kind = 'whatsapp'
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.message.send_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND channel.status = 'active'
    AND channel.kill_switch = false;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_whatsapp_message_sent(
  p_event_id uuid,
  p_worker_id text,
  p_provider_message_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE updated_count integer;
BEGIN
  IF p_provider_message_id IS NULL OR char_length(btrim(p_provider_message_id)) NOT BETWEEN 1 AND 320 THEN
    RAISE EXCEPTION 'provider message id is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.whatsapp_message_events AS message
  SET delivery_status = 'sent',
      provider_message_id = btrim(p_provider_message_id),
      sent_at = timezone('utc', now()),
      failed_at = NULL,
      provider_error_code = NULL
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.message.send_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND message.id = (event.payload ->> 'message_id')::uuid
    AND message.organization_id = event.organization_id;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_whatsapp_message_failed(
  p_event_id uuid,
  p_worker_id text,
  p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE updated_count integer;
BEGIN
  IF p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$' THEN
    RAISE EXCEPTION 'provider error code is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.whatsapp_message_events AS message
  SET delivery_status = 'failed',
      failed_at = timezone('utc', now()),
      provider_error_code = p_error_code
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.message.send_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND message.id = (event.payload ->> 'message_id')::uuid
    AND message.organization_id = event.organization_id;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_invitation_delivery_sent(
  p_event_id uuid,
  p_worker_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE updated_count integer;
BEGIN
  UPDATE public.organization_invitations AS invitation
  SET delivery_status = 'sent', updated_at = timezone('utc', now())
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type IN ('organization.invitation.send_requested', 'member.invitation.resent')
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND invitation.id = (event.payload ->> 'invitation_id')::uuid
    AND invitation.organization_id = event.organization_id;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_invitation_delivery_failed(
  p_event_id uuid,
  p_worker_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE updated_count integer;
BEGIN
  UPDATE public.organization_invitations AS invitation
  SET delivery_status = 'failed', updated_at = timezone('utc', now())
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type IN ('organization.invitation.send_requested', 'member.invitation.resent')
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND invitation.id = (event.payload ->> 'invitation_id')::uuid
    AND invitation.organization_id = event.organization_id;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count = 1;
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON FUNCTION public.claim_outbox_delivery_events(text, integer, integer) FROM anon;
    REVOKE ALL ON FUNCTION public.mark_outbox_event_needs_review(uuid, text, text) FROM anon;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_outbox_delivery_events(text, integer, integer) FROM PUBLIC, authenticated;
REVOKE ALL ON FUNCTION public.mark_outbox_event_needs_review(uuid, text, text) FROM PUBLIC, authenticated;
REVOKE ALL ON FUNCTION public.resolve_whatsapp_outbox_delivery(uuid, text) FROM PUBLIC, authenticated;
REVOKE ALL ON FUNCTION public.mark_whatsapp_message_sent(uuid, text, text) FROM PUBLIC, authenticated;
REVOKE ALL ON FUNCTION public.mark_whatsapp_message_failed(uuid, text, text) FROM PUBLIC, authenticated;
REVOKE ALL ON FUNCTION public.mark_invitation_delivery_sent(uuid, text) FROM PUBLIC, authenticated;
REVOKE ALL ON FUNCTION public.mark_invitation_delivery_failed(uuid, text) FROM PUBLIC, authenticated;
REVOKE ALL ON FUNCTION public.invite_organization_member_v1(uuid, text, text, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resend_organization_invitation_v1(uuid, uuid, text, text, uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.invite_organization_member_v1(uuid, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resend_organization_invitation_v1(uuid, uuid, text, text, uuid) TO authenticated;

GRANT USAGE ON SCHEMA public TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.claim_outbox_delivery_events(text, integer, integer) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.mark_outbox_event_needs_review(uuid, text, text) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.resolve_whatsapp_outbox_delivery(uuid, text) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.mark_whatsapp_message_sent(uuid, text, text) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.mark_whatsapp_message_failed(uuid, text, text) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.mark_invitation_delivery_sent(uuid, text) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.mark_invitation_delivery_failed(uuid, text) TO voya_outbox_worker, service_role;

-- Preserve the inbound webhook boundary while retaining the sender as a
-- tenant-scoped WhatsApp contact so a later human-reviewed reply has a safe
-- provider destination.
CREATE OR REPLACE FUNCTION public.ingest_whatsapp_webhook_event(
  p_provider text,
  p_external_channel_id text,
  p_external_conversation_key text,
  p_event_key text,
  p_sender_phone text,
  p_body_text text,
  p_received_at timestamptz DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_channel public.whatsapp_channels%ROWTYPE;
  v_conversation public.whatsapp_conversations%ROWTYPE;
  v_existing public.whatsapp_message_events%ROWTYPE;
  v_contact_method_id uuid;
  v_message_id uuid;
  v_received_at timestamptz := coalesce(p_received_at, timezone('utc', now()));
  v_contact_idempotency text := 'whatsapp-inbound-contact:' || encode(extensions.digest(btrim(p_sender_phone), 'sha256'), 'hex');
BEGIN
  IF p_provider IS NULL OR p_provider !~ '^[a-z][a-z0-9_.-]{0,79}$'
    OR p_external_channel_id IS NULL OR char_length(btrim(p_external_channel_id)) NOT BETWEEN 1 AND 256
    OR p_external_conversation_key IS NULL OR char_length(btrim(p_external_conversation_key)) NOT BETWEEN 1 AND 256
    OR p_event_key IS NULL OR char_length(btrim(p_event_key)) NOT BETWEEN 1 AND 320
    OR p_sender_phone IS NULL OR char_length(btrim(p_sender_phone)) NOT BETWEEN 1 AND 80
    OR p_body_text IS NULL OR char_length(btrim(p_body_text)) NOT BETWEEN 1 AND 4096 THEN
    RAISE EXCEPTION 'webhook event input is invalid' USING ERRCODE = '22023';
  END IF;
  IF v_received_at < timezone('utc', now()) - interval '30 days'
    OR v_received_at > timezone('utc', now()) + interval '10 minutes' THEN
    v_received_at := timezone('utc', now());
  END IF;

  SELECT channel.* INTO v_channel
  FROM public.whatsapp_channels AS channel
  WHERE channel.provider = btrim(p_provider)
    AND channel.external_channel_id = btrim(p_external_channel_id)
    AND channel.status = 'active'
    AND channel.kill_switch = false
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'webhook channel is unavailable' USING ERRCODE = '42501'; END IF;

  SELECT message.* INTO v_existing
  FROM public.whatsapp_message_events AS message
  WHERE message.organization_id = v_channel.organization_id
    AND message.event_key = btrim(p_event_key);
  IF FOUND THEN RETURN v_existing.id; END IF;

  SELECT contact.id INTO v_contact_method_id
  FROM public.crm_contact_methods AS contact
  WHERE contact.organization_id = v_channel.organization_id
    AND contact.kind = 'whatsapp'
    AND contact.normalized_value = btrim(p_sender_phone)
  FOR UPDATE;
  IF v_contact_method_id IS NULL THEN
    INSERT INTO public.crm_contact_methods (
      organization_id, kind, normalized_value, display_value, idempotency_key, created_by_membership_id
    ) VALUES (
      v_channel.organization_id, 'whatsapp', btrim(p_sender_phone), btrim(p_sender_phone),
      v_contact_idempotency, v_channel.created_by_membership_id
    ) ON CONFLICT (organization_id, kind, normalized_value) DO NOTHING
    RETURNING id INTO v_contact_method_id;
    IF v_contact_method_id IS NULL THEN
      SELECT contact.id INTO v_contact_method_id
      FROM public.crm_contact_methods AS contact
      WHERE contact.organization_id = v_channel.organization_id
        AND contact.kind = 'whatsapp'
        AND contact.normalized_value = btrim(p_sender_phone);
    END IF;
  END IF;

  SELECT conversation.* INTO v_conversation
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.organization_id = v_channel.organization_id
    AND conversation.channel_id = v_channel.id
    AND conversation.external_conversation_key = btrim(p_external_conversation_key)
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.whatsapp_conversations (
      organization_id, channel_id, contact_method_id, external_conversation_key, status, last_message_at
    ) VALUES (
      v_channel.organization_id, v_channel.id, v_contact_method_id,
      btrim(p_external_conversation_key), 'open', v_received_at
    )
    ON CONFLICT (organization_id, channel_id, external_conversation_key) DO UPDATE
      SET contact_method_id = coalesce(public.whatsapp_conversations.contact_method_id, EXCLUDED.contact_method_id),
          last_message_at = EXCLUDED.last_message_at
    RETURNING * INTO v_conversation;
  ELSIF v_conversation.contact_method_id IS NULL THEN
    UPDATE public.whatsapp_conversations
    SET contact_method_id = v_contact_method_id
    WHERE id = v_conversation.id;
    v_conversation.contact_method_id := v_contact_method_id;
  END IF;

  INSERT INTO public.whatsapp_message_events (
    organization_id, conversation_id, event_key, direction, body_text,
    delivery_status, created_at, idempotency_key
  ) VALUES (
    v_channel.organization_id, v_conversation.id, btrim(p_event_key), 'inbound', btrim(p_body_text),
    'received', v_received_at, 'provider:' || btrim(p_event_key)
  ) ON CONFLICT (organization_id, event_key) DO NOTHING
  RETURNING id INTO v_message_id;

  IF v_message_id IS NULL THEN
    SELECT message.id INTO v_message_id
    FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = v_channel.organization_id
      AND message.event_key = btrim(p_event_key);
  END IF;
  UPDATE public.whatsapp_conversations
  SET last_message_at = greatest(coalesce(last_message_at, v_received_at), v_received_at),
      status = CASE WHEN status = 'closed' THEN 'open' ELSE status END
  WHERE id = v_conversation.id AND organization_id = v_channel.organization_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, action, resource_type, resource_id, outcome, after_delta
  ) VALUES (
    v_channel.organization_id, 'system', 'whatsapp.webhook.received', 'whatsapp_message_event', v_message_id, 'success',
    jsonb_build_object('provider', p_provider, 'channel_id', v_channel.id, 'direction', 'inbound')
  ) ON CONFLICT DO NOTHING;
  RETURN v_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.ingest_whatsapp_webhook_event(text, text, text, text, text, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_whatsapp_webhook_event(text, text, text, text, text, text, timestamptz) TO service_role;

COMMENT ON COLUMN public.outbox_events.state IS 'pending, processing, retry_wait, completed, dead_letter, or needs_review';
