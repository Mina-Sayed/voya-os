-- Voya OS: human-sent WhatsApp reply drafts.
--
-- Proves the withheld-reply boundary: the worker can store a draft under the
-- conversation's own tenant only, the reason set fails closed, the record is
-- idempotent per (organization_id, dedupe_key), the staff queue is AAL2 and
-- membership gated, and a draft can be closed exactly once.
-- Run after supabase/migrations/20261019103000_whatsapp_reply_drafts.sql.
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- Catalog, grant posture and storage boundary
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF to_regclass('public.whatsapp_reply_drafts') IS NULL THEN
    RAISE EXCEPTION 'whatsapp_reply_drafts table is missing';
  END IF;
  IF to_regprocedure('public.record_whatsapp_reply_draft_v1(uuid,text,text[],text)') IS NULL
    OR to_regprocedure('public.list_whatsapp_reply_drafts_v1(integer)') IS NULL
    OR to_regprocedure('public.mark_whatsapp_reply_draft_sent_v1(uuid,uuid)') IS NULL
    OR to_regprocedure('public.discard_whatsapp_reply_draft_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'WhatsApp reply draft RPCs are missing';
  END IF;

  -- No overload may smuggle an organization argument past the boundary.
  IF to_regprocedure('public.record_whatsapp_reply_draft_v1(uuid,uuid,text,text[],text)') IS NOT NULL
    OR to_regprocedure('public.list_whatsapp_reply_drafts_v1(uuid)') IS NOT NULL
    OR to_regprocedure('public.list_whatsapp_reply_drafts_v1(uuid,integer)') IS NOT NULL
    OR to_regprocedure('public.mark_whatsapp_reply_draft_sent_v1(uuid,uuid,uuid)') IS NOT NULL
    OR to_regprocedure('public.discard_whatsapp_reply_draft_v1(uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'WhatsApp reply draft RPCs must not accept a client-supplied organization';
  END IF;
  IF pg_get_function_arguments('public.record_whatsapp_reply_draft_v1(uuid,text,text[],text)'::regprocedure)
    ILIKE '%organization%'
    OR pg_get_function_arguments('public.list_whatsapp_reply_drafts_v1(integer)'::regprocedure)
    ILIKE '%organization%' THEN
    RAISE EXCEPTION 'WhatsApp reply draft RPCs must derive the organization server-side';
  END IF;
  IF pg_get_function_result('public.list_whatsapp_reply_drafts_v1(integer)'::regprocedure)
    !~ '^SETOF (public\.)?whatsapp_reply_drafts$' THEN
    RAISE EXCEPTION 'list_whatsapp_reply_drafts_v1 must return the drafts table type';
  END IF;

  -- Worker-only write surface.
  IF has_function_privilege('anon', 'public.record_whatsapp_reply_draft_v1(uuid,text,text[],text)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.record_whatsapp_reply_draft_v1(uuid,text,text[],text)', 'EXECUTE')
    OR NOT has_function_privilege('voya_outbox_worker', 'public.record_whatsapp_reply_draft_v1(uuid,text,text[],text)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.record_whatsapp_reply_draft_v1(uuid,text,text[],text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'reply draft recording must stay worker/service-role only';
  END IF;
  IF has_function_privilege('anon', 'public.list_whatsapp_reply_drafts_v1(integer)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.mark_whatsapp_reply_draft_sent_v1(uuid,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.discard_whatsapp_reply_draft_v1(uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.list_whatsapp_reply_drafts_v1(integer)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.mark_whatsapp_reply_draft_sent_v1(uuid,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.discard_whatsapp_reply_draft_v1(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'reply draft staff RPCs must stay authenticated-only';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    CROSS JOIN LATERAL aclexplode(coalesce(routine.proacl, acldefault('f', routine.proowner))) AS privilege
    WHERE namespace.nspname = 'public'
      AND routine.proname IN (
        'record_whatsapp_reply_draft_v1', 'list_whatsapp_reply_drafts_v1',
        'mark_whatsapp_reply_draft_sent_v1', 'discard_whatsapp_reply_draft_v1'
      )
      AND privilege.grantee = 0
      AND privilege.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PUBLIC must not retain EXECUTE on reply draft RPCs';
  END IF;

  -- The drafts table is RPC-owned: no role may touch rows directly.
  IF has_table_privilege('anon', 'public.whatsapp_reply_drafts', 'SELECT')
    OR has_table_privilege('anon', 'public.whatsapp_reply_drafts', 'INSERT')
    OR has_table_privilege('authenticated', 'public.whatsapp_reply_drafts', 'SELECT')
    OR has_table_privilege('authenticated', 'public.whatsapp_reply_drafts', 'INSERT')
    OR has_table_privilege('authenticated', 'public.whatsapp_reply_drafts', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.whatsapp_reply_drafts', 'DELETE')
    OR has_table_privilege('service_role', 'public.whatsapp_reply_drafts', 'SELECT')
    OR has_table_privilege('voya_outbox_worker', 'public.whatsapp_reply_drafts', 'SELECT') THEN
    RAISE EXCEPTION 'reply drafts must remain RPC-only';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class AS relation
    WHERE relation.oid = 'public.whatsapp_reply_drafts'::regclass
      AND relation.relrowsecurity AND relation.relforcerowsecurity
  ) THEN
    RAISE EXCEPTION 'reply drafts must keep RLS enabled and forced';
  END IF;
  IF to_regclass('public.whatsapp_reply_drafts_pending_idx') IS NULL THEN
    RAISE EXCEPTION 'pending reply draft queue index is missing';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
\set voya_outside_user_id '9f1c7d20-4b6e-4d1a-9c33-00000000d00d'

-- Fixtures: two tenants, an active viewer, and a user with no membership
-- ---------------------------------------------------------------------------

INSERT INTO auth.users (id, email)
VALUES
  ('44444444-4444-4444-4444-444444444444', 'reply-drafts-viewer@example.test'),
  (:'voya_outside_user_id', 'reply-drafts-outsider@example.test')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '44444444-4444-4444-4444-444444444444', 'viewer', 'active')
ON CONFLICT (organization_id, user_id) DO NOTHING;

DO $$
DECLARE
  v_owner_a uuid;
  v_owner_b uuid;
BEGIN
  SELECT id INTO v_owner_a FROM public.organization_memberships
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND user_id = '11111111-1111-1111-1111-111111111111';
  SELECT id INTO v_owner_b FROM public.organization_memberships
  WHERE organization_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    AND user_id = '22222222-2222-2222-2222-222222222222';

  INSERT INTO public.whatsapp_channels (
    id, organization_id, provider, external_channel_id, display_name, created_by_membership_id
  ) VALUES
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'meta_cloud', 'reply-drafts-channel-a', 'Reply drafts channel A', v_owner_a),
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee03', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     'meta_cloud', 'reply-drafts-channel-b', 'Reply drafts channel B', v_owner_b)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.whatsapp_conversations (
    id, organization_id, channel_id, external_conversation_key
  ) VALUES
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 'reply-drafts-thread-a'),
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee04', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee03', 'reply-drafts-thread-b')
  ON CONFLICT (id) DO NOTHING;

  -- The message a human send produces before the draft is closed as sent.
  INSERT INTO public.whatsapp_message_events (
    id, organization_id, conversation_id, event_key, direction, body_text,
    delivery_status, idempotency_key
  ) VALUES (
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', 'reply-drafts-human-message-05',
    'outbound', 'رسالة بشرية للعميل', 'queued', 'reply-drafts-human-message-05'
  ) ON CONFLICT (id) DO NOTHING;
END;
$$;

-- ---------------------------------------------------------------------------
-- (a) the worker records a draft under the conversation's own tenant
-- ---------------------------------------------------------------------------

SET ROLE voya_outbox_worker;
SELECT public.record_whatsapp_reply_draft_v1(
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02',
  'العميل님، السعر النهائي 2500 جنيه لليلة والإتاحة متاحة من الأحد',
  ARRAY['monetary_amount', 'booking_commitment', 'availability_commitment'],
  'reply-drafts-a-1'
) AS draft_a_id \gset
RESET ROLE;
SELECT set_config('voya.test.draft_a_id', :'draft_a_id', false);

DO $$
BEGIN
  IF (SELECT count(*)
      FROM public.whatsapp_reply_drafts AS draft
      JOIN public.whatsapp_conversations AS conversation ON conversation.id = draft.conversation_id
      WHERE draft.id = current_setting('voya.test.draft_a_id')::uuid
        AND draft.organization_id = conversation.organization_id
        AND draft.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND draft.status = 'pending'
        AND draft.source = 'whatsapp_ai'
        AND draft.sent_message_id IS NULL
        AND draft.review_reasons = ARRAY['monetary_amount', 'booking_commitment', 'availability_commitment']
        AND draft.body_text = 'العميل님، السعر النهائي 2500 جنيه لليلة والإتاحة متاحة من الأحد'
        AND draft.updated_at >= draft.created_at) <> 1 THEN
    RAISE EXCEPTION 'worker-recorded draft must inherit the conversation organization';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.audit_events AS audit
    WHERE audit.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND audit.resource_id = current_setting('voya.test.draft_a_id')::uuid
      AND audit.action = 'whatsapp.reply_draft.recorded'
      AND audit.actor_type = 'system'
      AND audit.outcome = 'success'
  ) THEN
    RAISE EXCEPTION 'recording a withheld reply must write an audit event';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- (b) the dedupe key is idempotent, including for a second trusted caller
-- ---------------------------------------------------------------------------

SET ROLE service_role;
SELECT public.record_whatsapp_reply_draft_v1(
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02',
  'العميل님، السعر النهائي 2500 جنيه لليلة والإتاحة متاحة من الأحد',
  ARRAY['monetary_amount', 'booking_commitment', 'availability_commitment'],
  'reply-drafts-a-1'
) AS draft_a_replay_id \gset
RESET ROLE;
SELECT set_config('voya.test.draft_a_replay_id', :'draft_a_replay_id', false);

DO $$
BEGIN
  IF current_setting('voya.test.draft_a_replay_id') <> current_setting('voya.test.draft_a_id') THEN
    RAISE EXCEPTION 'replaying a dedupe key must return the existing draft id';
  END IF;
  IF (SELECT count(*) FROM public.whatsapp_reply_drafts WHERE dedupe_key = 'reply-drafts-a-1') <> 1 THEN
    RAISE EXCEPTION 'replaying a dedupe key must not create a second draft';
  END IF;
  IF (SELECT count(*)
      FROM public.audit_events
      WHERE resource_id = current_setting('voya.test.draft_a_id')::uuid
        AND action = 'whatsapp.reply_draft.recorded') <> 1 THEN
    RAISE EXCEPTION 'an idempotent replay must not duplicate the audit trail';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- (c) reason set fails closed, (d) body and key bounds fail closed
-- ---------------------------------------------------------------------------

SET ROLE voya_outbox_worker;
DO $$
BEGIN
  BEGIN
    PERFORM public.record_whatsapp_reply_draft_v1(
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', 'نص محجوز', ARRAY[]::text[], 'reply-drafts-empty-reasons'
    );
    RAISE EXCEPTION 'a draft without review reasons must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  BEGIN
    PERFORM public.record_whatsapp_reply_draft_v1(
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', 'نص محجوز', NULL::text[], 'reply-drafts-null-reasons'
    );
    RAISE EXCEPTION 'a draft with NULL review reasons must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  BEGIN
    PERFORM public.record_whatsapp_reply_draft_v1(
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', 'نص محجوز', ARRAY['refund_promise'], 'reply-drafts-unknown-reason'
    );
    RAISE EXCEPTION 'an unknown review reason must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  BEGIN
    PERFORM public.record_whatsapp_reply_draft_v1(
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', repeat('x', 4097),
      ARRAY['booking_commitment'], 'reply-drafts-long-body'
    );
    RAISE EXCEPTION 'an oversized body must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  BEGIN
    PERFORM public.record_whatsapp_reply_draft_v1(
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', '   ', ARRAY['booking_commitment'], 'reply-drafts-blank-body'
    );
    RAISE EXCEPTION 'a whitespace body must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  BEGIN
    PERFORM public.record_whatsapp_reply_draft_v1(
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', 'نص صالح', ARRAY['booking_commitment'], '   '
    );
    RAISE EXCEPTION 'a blank dedupe key must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  BEGIN
    PERFORM public.record_whatsapp_reply_draft_v1(
      'eeeeeeee-eeee-4eee-8eee-999999999999', 'نص صالح', ARRAY['booking_commitment'], 'reply-drafts-missing-conversation'
    );
    RAISE EXCEPTION 'an unknown conversation must be rejected';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

-- None of the rejected calls may have persisted anything.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.whatsapp_reply_drafts
    WHERE dedupe_key IN (
      'reply-drafts-empty-reasons', 'reply-drafts-null-reasons', 'reply-drafts-unknown-reason',
      'reply-drafts-long-body', 'reply-drafts-blank-body', 'reply-drafts-missing-conversation'
    )
  ) THEN
    RAISE EXCEPTION 'rejected drafts must not be persisted';
  END IF;
END;
$$;

-- The second tenant's conversation files its own draft under its own tenant.
SET ROLE voya_outbox_worker;
SELECT public.record_whatsapp_reply_draft_v1(
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee04',
  'العميلة في tenancy B: الإتاحة مؤكدة من الأحد',
  ARRAY['availability_commitment'],
  'reply-drafts-b-1'
) AS draft_b_id \gset
RESET ROLE;
SELECT set_config('voya.test.draft_b_id', :'draft_b_id', false);

DO $$
BEGIN
  IF (SELECT organization_id FROM public.whatsapp_reply_drafts WHERE id = current_setting('voya.test.draft_b_id')::uuid)
    <> 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' THEN
    RAISE EXCEPTION 'the second tenant draft must stay inside its own organization';
  END IF;
  IF current_setting('voya.test.draft_b_id') = current_setting('voya.test.draft_a_id') THEN
    RAISE EXCEPTION 'dedupe keys are unique per organization, not globally';
  END IF;
END;
$$;

SET ROLE voya_outbox_worker;
SELECT public.record_whatsapp_reply_draft_v1(
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02',
  'رسالة ثانية تحتاج مراجعة بشرية',
  ARRAY['booking_commitment'],
  'reply-drafts-a-2'
) AS draft_a2_id \gset
RESET ROLE;
SELECT set_config('voya.test.draft_a2_id', :'draft_a2_id', false);

-- ---------------------------------------------------------------------------
-- (e) the staff queue is tenant scoped to the caller's own memberships
-- ---------------------------------------------------------------------------

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
DECLARE
  v_seen integer;
  v_foreign integer;
BEGIN
  SELECT count(*) INTO v_seen FROM public.list_whatsapp_reply_drafts_v1(50);
  IF v_seen <> 2 THEN
    RAISE EXCEPTION 'tenant A owner must see exactly its two pending drafts, saw %', v_seen;
  END IF;
  SELECT count(*) INTO v_foreign
  FROM public.list_whatsapp_reply_drafts_v1(50) AS draft
  WHERE draft.organization_id <> 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  IF v_foreign <> 0 THEN
    RAISE EXCEPTION 'tenant A owner must never see another organization draft';
  END IF;
  IF (SELECT count(*) FROM public.list_whatsapp_reply_drafts_v1(50) AS draft
      WHERE draft.id = current_setting('voya.test.draft_b_id')::uuid) <> 0 THEN
    RAISE EXCEPTION 'tenant B draft must not appear in the tenant A queue';
  END IF;
  -- Bounds: non-positive is rejected, oversized clamps instead of failing.
  BEGIN
    PERFORM public.list_whatsapp_reply_drafts_v1(0);
    RAISE EXCEPTION 'a non-positive limit must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
  BEGIN
    PERFORM public.list_whatsapp_reply_drafts_v1(NULL);
    RAISE EXCEPTION 'a NULL limit must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
  IF (SELECT count(*) FROM public.list_whatsapp_reply_drafts_v1(5000)) <> 2 THEN
    RAISE EXCEPTION 'an oversized limit must clamp to the pending queue';
  END IF;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
BEGIN
  IF (SELECT count(*) FROM public.list_whatsapp_reply_drafts_v1(50)) <> 1 THEN
    RAISE EXCEPTION 'tenant B owner must see exactly its own pending draft';
  END IF;
  IF (SELECT count(*) FROM public.list_whatsapp_reply_drafts_v1(50) AS draft
      WHERE draft.id = current_setting('voya.test.draft_a_id')::uuid) <> 0 THEN
    RAISE EXCEPTION 'tenant B owner must never see a tenant A draft';
  END IF;
END;
$$;
RESET ROLE;

-- ---------------------------------------------------------------------------
-- (f) role and membership denial on the staff surface
-- ---------------------------------------------------------------------------

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '44444444-4444-4444-4444-444444444444', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_whatsapp_reply_drafts_v1(50);
    RAISE EXCEPTION 'a viewer must not read reply drafts';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.mark_whatsapp_reply_draft_sent_v1(
      current_setting('voya.test.draft_a_id')::uuid,
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05'::uuid
    );
    RAISE EXCEPTION 'a viewer must not mark a reply draft sent';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.discard_whatsapp_reply_draft_v1(current_setting('voya.test.draft_a_id')::uuid);
    RAISE EXCEPTION 'a viewer must not discard a reply draft';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

-- A user with no membership at all is denied, not served an empty queue.
-- The id is deliberately not one of the shared fixture users used by other proofs,
-- which already carry memberships by the time this file runs. It is passed through a
-- psql variable so the fixture id is declared once, next to the row that creates it.
SELECT set_config('request.jwt.claim.sub', :'voya_outside_user_id', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_whatsapp_reply_drafts_v1(50);
    RAISE EXCEPTION 'a user without membership must not read reply drafts';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.discard_whatsapp_reply_draft_v1(current_setting('voya.test.draft_a_id')::uuid);
    RAISE EXCEPTION 'a user without membership must not discard a reply draft';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

-- An authenticated member of another tenant cannot close this tenant's draft.
SELECT set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.mark_whatsapp_reply_draft_sent_v1(
      current_setting('voya.test.draft_a_id')::uuid,
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05'::uuid
    );
    RAISE EXCEPTION 'a cross-tenant staff member must not close another tenant draft';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.whatsapp_reply_drafts WHERE id = current_setting('voya.test.draft_a_id')::uuid) <> 'pending' THEN
    RAISE EXCEPTION 'denied callers must not change a draft';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- (g) anon, unauthenticated, and the worker-only write surface
-- ---------------------------------------------------------------------------

SET ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM public.record_whatsapp_reply_draft_v1(
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', 'نص', ARRAY['booking_commitment'], 'anon-draft'
    );
    RAISE EXCEPTION 'anon must not record reply drafts';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.list_whatsapp_reply_drafts_v1(50);
    RAISE EXCEPTION 'anon must not read reply drafts';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.mark_whatsapp_reply_draft_sent_v1(
      current_setting('voya.test.draft_a_id')::uuid,
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05'::uuid
    );
    RAISE EXCEPTION 'anon must not mark reply drafts sent';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.discard_whatsapp_reply_draft_v1(current_setting('voya.test.draft_a_id')::uuid);
    RAISE EXCEPTION 'anon must not discard reply drafts';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.record_whatsapp_reply_draft_v1(
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', 'نص', ARRAY['booking_commitment'], 'browser-draft'
    );
    RAISE EXCEPTION 'authenticated staff must not record drafts through the worker RPC';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

-- No JWT subject at all: nothing is permitted even with a valid role grant.
SELECT set_config('request.jwt.claim.sub', '', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_whatsapp_reply_drafts_v1(50);
    RAISE EXCEPTION 'an unauthenticated caller must not read reply drafts';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.mark_whatsapp_reply_draft_sent_v1(
      current_setting('voya.test.draft_a_id')::uuid,
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05'::uuid
    );
    RAISE EXCEPTION 'an unauthenticated caller must not mark reply drafts sent';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.discard_whatsapp_reply_draft_v1(current_setting('voya.test.draft_a_id')::uuid);
    RAISE EXCEPTION 'an unauthenticated caller must not discard reply drafts';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

-- ---------------------------------------------------------------------------
-- (j) the queue is MFA AAL2 workspace data, proven at the database boundary
-- ---------------------------------------------------------------------------

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal1', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_whatsapp_reply_drafts_v1(50);
    RAISE EXCEPTION 'an AAL1 session must not read reply drafts';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.mark_whatsapp_reply_draft_sent_v1(
      current_setting('voya.test.draft_a_id')::uuid,
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05'::uuid
    );
    RAISE EXCEPTION 'an AAL1 session must not mark reply drafts sent';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.discard_whatsapp_reply_draft_v1(current_setting('voya.test.draft_a_id')::uuid);
    RAISE EXCEPTION 'an AAL1 session must not discard reply drafts';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Close the queue: mark sent once, discard once, never twice
-- ---------------------------------------------------------------------------

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
SELECT public.mark_whatsapp_reply_draft_sent_v1(
  :'draft_a_id'::uuid, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05'::uuid
) AS marked_draft_id \gset
SELECT public.discard_whatsapp_reply_draft_v1(:'draft_a2_id'::uuid) AS discarded_draft_id \gset
SELECT set_config('voya.test.marked_draft_id', :'marked_draft_id', false);
SELECT set_config('voya.test.discarded_draft_id', :'discarded_draft_id', false);
DO $$
BEGIN
  IF current_setting('voya.test.marked_draft_id') IS DISTINCT FROM current_setting('voya.test.draft_a_id')
    OR current_setting('voya.test.discarded_draft_id') IS DISTINCT FROM current_setting('voya.test.draft_a2_id') THEN
    RAISE EXCEPTION 'closing a draft must return its id';
  END IF;
  IF (SELECT count(*)
      FROM public.list_whatsapp_reply_drafts_v1(50) AS draft
      WHERE draft.id IN (
        current_setting('voya.test.draft_a_id')::uuid,
        current_setting('voya.test.draft_a2_id')::uuid
      )) <> 0 THEN
    RAISE EXCEPTION 'closed drafts must leave the pending queue';
  END IF;

  -- A second close of the same draft is an error, not a silent no-op.
  BEGIN
    PERFORM public.mark_whatsapp_reply_draft_sent_v1(
      current_setting('voya.test.draft_a_id')::uuid,
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05'::uuid
    );
    RAISE EXCEPTION 'an already sent draft must not be sent twice';
  EXCEPTION WHEN serialization_failure THEN
    NULL;
  END;
  BEGIN
    PERFORM public.discard_whatsapp_reply_draft_v1(current_setting('voya.test.draft_a_id')::uuid);
    RAISE EXCEPTION 'an already sent draft must not be discarded';
  EXCEPTION WHEN serialization_failure THEN
    NULL;
  END;
  BEGIN
    PERFORM public.discard_whatsapp_reply_draft_v1(current_setting('voya.test.draft_a2_id')::uuid);
    RAISE EXCEPTION 'an already discarded draft must not be discarded twice';
  EXCEPTION WHEN serialization_failure THEN
    NULL;
  END;
  BEGIN
    PERFORM public.mark_whatsapp_reply_draft_sent_v1(
      current_setting('voya.test.draft_a2_id')::uuid,
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05'::uuid
    );
    RAISE EXCEPTION 'a discarded draft must not be sent';
  EXCEPTION WHEN serialization_failure THEN
    NULL;
  END;

  -- A sent draft always carries the message the human send path produced;
  -- the stored columns are asserted below as the schema owner, because this
  -- block deliberately runs as `authenticated`, which has no table access.

  -- Marking a draft sent without the human message is rejected.
  BEGIN
    PERFORM public.mark_whatsapp_reply_draft_sent_v1(
      current_setting('voya.test.draft_a_id')::uuid, NULL
    );
    RAISE EXCEPTION 'marking a draft sent without a message must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

-- The tenant-qualified sent-message FK refuses another tenant's message id.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.mark_whatsapp_reply_draft_sent_v1(
      current_setting('voya.test.draft_b_id')::uuid,
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05'::uuid
    );
    RAISE EXCEPTION 'a cross-tenant message must not close a draft';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.whatsapp_reply_drafts WHERE id = current_setting('voya.test.draft_a_id')::uuid)
      <> 'sent'
    OR (SELECT status FROM public.whatsapp_reply_drafts WHERE id = current_setting('voya.test.draft_a2_id')::uuid)
      <> 'discarded'
    OR (SELECT status FROM public.whatsapp_reply_drafts WHERE id = current_setting('voya.test.draft_b_id')::uuid)
      <> 'pending' THEN
    RAISE EXCEPTION 'draft lifecycle statuses are wrong';
  END IF;
  IF (SELECT sent_message_id FROM public.whatsapp_reply_drafts WHERE id = current_setting('voya.test.draft_a_id')::uuid)
    <> 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05'::uuid THEN
    RAISE EXCEPTION 'marking a draft sent must record the human message';
  END IF;
  IF (SELECT sent_message_id FROM public.whatsapp_reply_drafts WHERE id = current_setting('voya.test.draft_a2_id')::uuid)
    IS NOT NULL THEN
    RAISE EXCEPTION 'a discarded draft must not carry a sent message';
  END IF;
  IF (SELECT count(*)
      FROM public.audit_events
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND action = 'whatsapp.reply_draft.sent'
        AND resource_id = current_setting('voya.test.draft_a_id')::uuid
        AND actor_type = 'user'
        AND outcome = 'success') <> 1 THEN
    RAISE EXCEPTION 'marking a draft sent must write exactly one audit event';
  END IF;
  IF (SELECT count(*)
      FROM public.audit_events
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND action = 'whatsapp.reply_draft.discarded'
        AND resource_id = current_setting('voya.test.draft_a2_id')::uuid
        AND outcome = 'success') <> 1 THEN
    RAISE EXCEPTION 'discarding a draft must write exactly one audit event';
  END IF;
  IF (SELECT count(*) FROM public.whatsapp_reply_drafts) <> 3 THEN
    RAISE EXCEPTION 'unexpected reply draft row count';
  END IF;
END;
$$;

SELECT 'WhatsApp reply drafts database integration tests passed' AS result;