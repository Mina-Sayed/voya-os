-- Voya OS: human-sent WhatsApp reply drafts.
--
-- Booking confirmation and sending listing data to a customer must stay
-- strictly human. The deterministic reply gate withholds any AI reply that
-- carries money, a booking commitment, or an availability claim; a withheld
-- reply must not be silently dropped, so it is stored here as a pending draft
-- that staff review and send from the workspace inbox.
--
-- Storage only. This migration adds no send path: staff still send through
-- the existing human boundary public.create_whatsapp_message(...) and then
-- close the draft with mark_whatsapp_reply_draft_sent_v1.
--
-- Boundary posture:
--   * record_..._v1 is a worker surface (voya_outbox_worker / service_role).
--     It takes no organization argument; the tenant is derived from the
--     conversation row so a worker can never file a draft into another tenant.
--   * list/mark/discard are authenticated staff surfaces gated by
--     require_workspace_aal2_v1() (the inbox is MFA AAL2 workspace data) and
--     by an owner/manager/operations active membership resolved from
--     auth.uid(). No client-supplied organization id is trusted anywhere.
--   * The table has no direct privileges for any role; RLS is enabled and
--     forced so every read and write travels through the RPCs below.
--
-- Re-runnable: CREATE TABLE IF NOT EXISTS, CREATE OR REPLACE FUNCTION,
-- CREATE INDEX IF NOT EXISTS, and restated REVOKE/GRANT statements.

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

-- Tenant-qualified uniqueness on the referenced message table is normally added by
-- 20260827153809_whatsapp_ai_agent_phase1.sql. The disposable harness can apply
-- migrations in an order where this file runs first, so the draft table must not
-- depend on that ordering: add the constraint only when it is genuinely missing.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.whatsapp_message_events'::regclass
      AND contype = 'u'
      AND conname = 'whatsapp_message_organization_id_unique'
  ) THEN
    ALTER TABLE public.whatsapp_message_events
      ADD CONSTRAINT whatsapp_message_organization_id_unique UNIQUE (organization_id, id);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.whatsapp_conversations'::regclass
      AND contype = 'u'
      AND conname = 'whatsapp_conversation_organization_id_unique'
  ) THEN
    ALTER TABLE public.whatsapp_conversations
      ADD CONSTRAINT whatsapp_conversation_organization_id_unique UNIQUE (organization_id, id);
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.whatsapp_reply_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  conversation_id uuid NOT NULL,
  body_text text NOT NULL CHECK (char_length(btrim(body_text)) BETWEEN 1 AND 4096),
  review_reasons text[] NOT NULL,
  source text NOT NULL DEFAULT 'whatsapp_ai' CHECK (source IN ('whatsapp_ai')),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'discarded')),
  dedupe_key text NOT NULL CHECK (char_length(btrim(dedupe_key)) > 0),
  sent_message_id uuid,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  -- Fail closed on the reason set: a withheld reply with no recorded reason is
  -- a gate bug, so the empty array and any unknown value are rejected here as
  -- well as in the command RPC.
  CONSTRAINT whatsapp_reply_draft_review_reasons_check CHECK (
    cardinality(review_reasons) BETWEEN 1 AND 3
    AND review_reasons <@ ARRAY[
      'booking_commitment', 'monetary_amount', 'availability_commitment'
    ]::text[]
  ),
  -- The sent message must belong to the same tenant as the draft.
  CONSTRAINT whatsapp_reply_draft_sent_message_in_organization_fk
    FOREIGN KEY (organization_id, sent_message_id)
    REFERENCES public.whatsapp_message_events (organization_id, id) ON DELETE RESTRICT,
  -- Tenant-qualified foreign keys: a draft row must never be able to point at a
  -- conversation (or a sent message) that belongs to another organization.
  CONSTRAINT whatsapp_reply_draft_conversation_in_organization_fk
    FOREIGN KEY (organization_id, conversation_id)
    REFERENCES public.whatsapp_conversations (organization_id, id) ON DELETE CASCADE,
  -- Only a sent draft may carry the message the human send path produced.
  CONSTRAINT whatsapp_reply_draft_sent_status_consistency CHECK (
    (status = 'sent') = (sent_message_id IS NOT NULL)
  ),
  CONSTRAINT whatsapp_reply_draft_dedupe_unique UNIQUE (organization_id, dedupe_key)
);

CREATE INDEX IF NOT EXISTS whatsapp_reply_drafts_pending_idx
  ON public.whatsapp_reply_drafts (organization_id, created_at DESC, id DESC)
  WHERE status = 'pending';

ALTER TABLE public.whatsapp_reply_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_reply_drafts FORCE ROW LEVEL SECURITY;

-- No role reads or writes drafts directly; the RPCs below are the only doors.
REVOKE ALL ON TABLE public.whatsapp_reply_drafts
  FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker;

-- ---------------------------------------------------------------------------
-- Worker: store a withheld reply for human review
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.record_whatsapp_reply_draft_v1(
  p_conversation_id uuid,
  p_body_text text,
  p_review_reasons text[],
  p_dedupe_key text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_conversation public.whatsapp_conversations%ROWTYPE;
  v_organization_id uuid;
  v_reason text;
  v_draft_id uuid;
BEGIN
  IF p_conversation_id IS NULL
    OR p_body_text IS NULL OR char_length(btrim(p_body_text)) NOT BETWEEN 1 AND 4096
    OR p_dedupe_key IS NULL OR char_length(btrim(p_dedupe_key)) NOT BETWEEN 1 AND 320 THEN
    RAISE EXCEPTION 'WhatsApp reply draft input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_review_reasons IS NULL OR cardinality(p_review_reasons) NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION 'WhatsApp reply draft requires at least one review reason' USING ERRCODE = '22023';
  END IF;
  FOREACH v_reason IN ARRAY p_review_reasons LOOP
    IF v_reason NOT IN ('booking_commitment', 'monetary_amount', 'availability_commitment') THEN
      RAISE EXCEPTION 'WhatsApp reply draft review reason is not permitted: %', v_reason USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- The tenant is read from the conversation, never from an argument.
  SELECT conversation.* INTO v_conversation
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.id = p_conversation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'WhatsApp conversation is invalid' USING ERRCODE = '23503';
  END IF;
  v_organization_id := v_conversation.organization_id;

  SELECT draft.id INTO v_draft_id
  FROM public.whatsapp_reply_drafts AS draft
  WHERE draft.organization_id = v_organization_id
    AND draft.dedupe_key = btrim(p_dedupe_key);
  IF v_draft_id IS NOT NULL THEN
    -- A retry re-generates the reply, so a still-pending draft must show the latest
    -- text a human will actually send. A draft a human already closed is never
    -- reopened.
    UPDATE public.whatsapp_reply_drafts
    SET body_text = btrim(p_body_text),
        review_reasons = p_review_reasons,
        updated_at = timezone('utc', now())
    WHERE id = v_draft_id AND status = 'pending';
    RETURN v_draft_id;
  END IF;

  BEGIN
    INSERT INTO public.whatsapp_reply_drafts (
      organization_id, conversation_id, body_text, review_reasons, dedupe_key
    ) VALUES (
      v_organization_id, p_conversation_id, btrim(p_body_text), p_review_reasons, btrim(p_dedupe_key)
    ) RETURNING id INTO v_draft_id;
  EXCEPTION WHEN unique_violation THEN
    -- A concurrent worker claimed the same dedupe key first.
    SELECT draft.id INTO v_draft_id
    FROM public.whatsapp_reply_drafts AS draft
    WHERE draft.organization_id = v_organization_id
      AND draft.dedupe_key = btrim(p_dedupe_key);
    IF v_draft_id IS NULL THEN
      RAISE EXCEPTION 'WhatsApp reply draft idempotency key is not reusable' USING ERRCODE = '40001';
    END IF;
    UPDATE public.whatsapp_reply_drafts
    SET body_text = btrim(p_body_text),
        review_reasons = p_review_reasons,
        updated_at = timezone('utc', now())
    WHERE id = v_draft_id AND status = 'pending';
    RETURN v_draft_id;
  END;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, after_delta
  ) VALUES (
    v_organization_id, 'system', NULL, 'whatsapp.reply_draft.recorded', 'whatsapp_reply_draft',
    v_draft_id, 'success',
    jsonb_build_object(
      'conversation_id', p_conversation_id,
      'review_reasons', p_review_reasons,
      'source', 'whatsapp_ai'
    )
  );
  RETURN v_draft_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Staff: review the pending queue
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.list_whatsapp_reply_drafts_v1(
  p_limit integer DEFAULT 50
)
RETURNS SETOF public.whatsapp_reply_drafts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_limit integer;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_limit IS NULL OR p_limit < 1 THEN
    RAISE EXCEPTION 'WhatsApp reply draft limit is invalid' USING ERRCODE = '22023';
  END IF;
  v_limit := least(p_limit, 200);

  IF NOT EXISTS (
    SELECT 1
    FROM public.organization_memberships AS membership
    WHERE membership.user_id = auth.uid()
      AND membership.status = 'active'
      AND membership.role IN ('owner', 'manager', 'operations')
  ) THEN
    RAISE EXCEPTION 'WhatsApp reply draft read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT draft.*
  FROM public.whatsapp_reply_drafts AS draft
  WHERE draft.status = 'pending'
    AND EXISTS (
      SELECT 1
      FROM public.organization_memberships AS membership
      WHERE membership.organization_id = draft.organization_id
        AND membership.user_id = auth.uid()
        AND membership.status = 'active'
        AND membership.role IN ('owner', 'manager', 'operations')
    )
  ORDER BY draft.created_at DESC, draft.id DESC
  LIMIT v_limit;
END;
$$;

-- ---------------------------------------------------------------------------
-- Staff: close a reviewed draft
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.mark_whatsapp_reply_draft_sent_v1(
  p_draft_id uuid,
  p_sent_message_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_membership_id uuid;
  v_organization_id uuid;
  v_status text;
  v_updated integer;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_draft_id IS NULL OR p_sent_message_id IS NULL THEN
    RAISE EXCEPTION 'WhatsApp reply draft input is invalid' USING ERRCODE = '22023';
  END IF;

  -- Tenant and role come from the caller's own membership, never from input.
  SELECT draft.organization_id, membership.id
    INTO v_organization_id, v_membership_id
  FROM public.whatsapp_reply_drafts AS draft
  JOIN public.organization_memberships AS membership
    ON membership.organization_id = draft.organization_id
   AND membership.user_id = auth.uid()
   AND membership.status = 'active'
   AND membership.role IN ('owner', 'manager', 'operations')
  WHERE draft.id = p_draft_id;
  IF v_membership_id IS NULL THEN
    RAISE EXCEPTION 'WhatsApp reply draft update is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT draft.status INTO v_status
  FROM public.whatsapp_reply_drafts AS draft
  WHERE draft.id = p_draft_id
    AND draft.organization_id = v_organization_id
  FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'WhatsApp reply draft is invalid' USING ERRCODE = '23503';
  END IF;
  IF v_status <> 'pending' THEN
    RAISE EXCEPTION 'WhatsApp reply draft is already %', v_status USING ERRCODE = '40001';
  END IF;

  -- The closing message must be this draft's own outbound message in this tenant's
  -- conversation; otherwise the audit trail could claim a reply that belongs to a
  -- different conversation.
  IF NOT EXISTS (
    SELECT 1
    FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = v_organization_id
      AND message.id = p_sent_message_id
      AND message.conversation_id = (
        SELECT draft.conversation_id
        FROM public.whatsapp_reply_drafts AS draft
        WHERE draft.id = p_draft_id
      )
      AND message.direction = 'outbound'
  ) THEN
    RAISE EXCEPTION 'WhatsApp reply draft message does not belong to this conversation' USING ERRCODE = '23503';
  END IF;

  UPDATE public.whatsapp_reply_drafts
  SET status = 'sent',
      sent_message_id = p_sent_message_id,
      updated_at = timezone('utc', now())
  WHERE id = p_draft_id
    AND organization_id = v_organization_id
    AND status = 'pending';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'WhatsApp reply draft is no longer pending' USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, after_delta
  ) VALUES (
    v_organization_id, 'user', v_membership_id, 'whatsapp.reply_draft.sent', 'whatsapp_reply_draft',
    p_draft_id, 'success',
    jsonb_build_object('status', 'sent', 'sent_message_id', p_sent_message_id)
  );
  RETURN p_draft_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.discard_whatsapp_reply_draft_v1(
  p_draft_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_membership_id uuid;
  v_organization_id uuid;
  v_status text;
  v_updated integer;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_draft_id IS NULL THEN
    RAISE EXCEPTION 'WhatsApp reply draft input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT draft.organization_id, membership.id
    INTO v_organization_id, v_membership_id
  FROM public.whatsapp_reply_drafts AS draft
  JOIN public.organization_memberships AS membership
    ON membership.organization_id = draft.organization_id
   AND membership.user_id = auth.uid()
   AND membership.status = 'active'
   AND membership.role IN ('owner', 'manager', 'operations')
  WHERE draft.id = p_draft_id;
  IF v_membership_id IS NULL THEN
    RAISE EXCEPTION 'WhatsApp reply draft update is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT draft.status INTO v_status
  FROM public.whatsapp_reply_drafts AS draft
  WHERE draft.id = p_draft_id
    AND draft.organization_id = v_organization_id
  FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'WhatsApp reply draft is invalid' USING ERRCODE = '23503';
  END IF;
  IF v_status <> 'pending' THEN
    RAISE EXCEPTION 'WhatsApp reply draft is already %', v_status USING ERRCODE = '40001';
  END IF;

  UPDATE public.whatsapp_reply_drafts
  SET status = 'discarded',
      updated_at = timezone('utc', now())
  WHERE id = p_draft_id
    AND organization_id = v_organization_id
    AND status = 'pending';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'WhatsApp reply draft is no longer pending' USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, after_delta
  ) VALUES (
    v_organization_id, 'user', v_membership_id, 'whatsapp.reply_draft.discarded',
    'whatsapp_reply_draft', p_draft_id, 'success',
    jsonb_build_object('status', 'discarded')
  );
  RETURN p_draft_id;
END;
$$;

REVOKE ALL ON FUNCTION public.record_whatsapp_reply_draft_v1(uuid, text, text[], text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_whatsapp_reply_draft_v1(uuid, text, text[], text)
  TO voya_outbox_worker, service_role;

REVOKE ALL ON FUNCTION public.list_whatsapp_reply_drafts_v1(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_whatsapp_reply_drafts_v1(integer)
  TO authenticated;

REVOKE ALL ON FUNCTION public.mark_whatsapp_reply_draft_sent_v1(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_whatsapp_reply_draft_sent_v1(uuid, uuid)
  TO authenticated;

REVOKE ALL ON FUNCTION public.discard_whatsapp_reply_draft_v1(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.discard_whatsapp_reply_draft_v1(uuid)
  TO authenticated;