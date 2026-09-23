-- Voya OS: idempotent WhatsApp internal notes.
--
-- Forward-only hardening for add_whatsapp_internal_note (introduced in
-- 20260801000200_crm_whatsapp_inbox.sql): a double-click on "save note" used
-- to insert two rows because the RPC accepted no idempotency key while every
-- sibling command (messages, fleet, tasks) already dedupes on one. This
-- migration backfills legacy NULL keys, requires the key at the schema
-- boundary, and rewrites the RPC with stable retry returns-same-row
-- semantics: same (org, key) + same payload returns the existing id without
-- duplicate audit evidence; same key with a different payload raises 23505.
-- Role gates (owner/manager/sales_agent/operations) are unchanged. The legacy
-- four-argument signature stays defined for history but is revoked from the
-- browser role; retries must go through the five-argument RPC below.
-- Channel creation needs no change: whatsapp_channel_external_unique already
-- rejects same-definition replays with 23505.

ALTER TABLE public.whatsapp_internal_notes
  ADD COLUMN IF NOT EXISTS idempotency_key text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.whatsapp_internal_notes'::regclass
      AND conname = 'whatsapp_internal_notes_idempotency_key_check'
  ) THEN
    ALTER TABLE public.whatsapp_internal_notes
      ADD CONSTRAINT whatsapp_internal_notes_idempotency_key_check
      CHECK (idempotency_key IS NULL OR char_length(btrim(idempotency_key)) BETWEEN 1 AND 160);
  END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS whatsapp_internal_notes_idempotency_idx
  ON public.whatsapp_internal_notes (organization_id, idempotency_key);

-- Backfill rows created through the legacy non-idempotent RPC so the NOT NULL
-- enforcement below is safe. The key embeds the globally unique row id,
-- therefore it is unique per organization as well and satisfies the 1–160 check.
UPDATE public.whatsapp_internal_notes
SET idempotency_key = 'legacy-note:' || id::text
WHERE idempotency_key IS NULL;

ALTER TABLE public.whatsapp_internal_notes ALTER COLUMN idempotency_key SET NOT NULL;

CREATE OR REPLACE FUNCTION public.add_whatsapp_internal_note(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_note_text text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_role text;
  v_id uuid;
  v_existing public.whatsapp_internal_notes%ROWTYPE;
  v_key text := btrim(p_idempotency_key);
BEGIN
  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'note creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_note_text IS NULL OR char_length(btrim(p_note_text)) NOT BETWEEN 1 AND 4096
    OR p_idempotency_key IS NULL OR char_length(v_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'note input is invalid' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.whatsapp_conversations AS conversation
    WHERE conversation.id = p_conversation_id
      AND conversation.organization_id = p_organization_id
      AND (
        v_role IN ('owner', 'manager')
        OR conversation.assigned_membership_id IS NULL
        OR conversation.assigned_membership_id = v_actor
      )
  ) THEN
    RAISE EXCEPTION 'conversation is not permitted' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.whatsapp_internal_notes (
    organization_id, conversation_id, note_text, created_by_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, p_conversation_id, btrim(p_note_text), v_actor, v_key
  )
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT note.* INTO v_existing
    FROM public.whatsapp_internal_notes AS note
    WHERE note.organization_id = p_organization_id AND note.idempotency_key = v_key;
    IF NOT FOUND
      OR v_existing.conversation_id IS DISTINCT FROM p_conversation_id
      OR v_existing.note_text <> btrim(p_note_text) THEN
      RAISE EXCEPTION 'idempotency key belongs to a different note' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'whatsapp.note.created', 'whatsapp_internal_note',
    v_id, 'success', p_request_id, jsonb_build_object('conversation_id', p_conversation_id)
  );
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.add_whatsapp_internal_note(uuid, uuid, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_whatsapp_internal_note(uuid, uuid, text, text, uuid) TO authenticated;

-- Legacy non-idempotent signature stays defined for history but must not be
-- executable by the browser role; retries must go through the RPC above.
REVOKE ALL ON FUNCTION public.add_whatsapp_internal_note(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
