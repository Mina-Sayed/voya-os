-- Human-confirmed AI data-entry draft boundary checks.

DO $$
BEGIN
  IF to_regclass('public.ai_data_entry_drafts') IS NULL
    OR to_regclass('public.ai_data_entry_inputs') IS NULL
    OR to_regprocedure('public.create_ai_data_entry_draft_v1(uuid,text,text,uuid)') IS NULL
    OR to_regprocedure('public.register_ai_data_entry_input_v1(uuid,uuid,text,text,bigint,text,text,uuid)') IS NULL
    OR to_regprocedure('public.submit_ai_data_entry_draft_v1(uuid,uuid,text,uuid)') IS NULL
    OR to_regprocedure('public.begin_ai_data_entry_confirmation_v1(uuid,uuid,jsonb,integer,text,uuid)') IS NULL
    OR to_regprocedure('public.record_ai_data_entry_progress_v1(uuid,uuid,text,jsonb,integer,text,uuid)') IS NULL
    OR to_regprocedure('public.mark_ai_data_entry_input_mapped_v1(uuid,uuid,uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'AI data-entry draft boundary is missing';
  END IF;
  IF has_table_privilege('authenticated', 'public.ai_data_entry_drafts', 'INSERT')
    OR has_table_privilege('authenticated', 'public.ai_data_entry_inputs', 'INSERT') THEN
    RAISE EXCEPTION 'browser role must use AI data-entry RPCs, not direct table writes';
  END IF;
  IF has_function_privilege('anon', 'public.create_ai_data_entry_draft_v1(uuid,text,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not create AI data-entry drafts';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'اسم العميل أحمد ومعلومة غير مدعومة 150 متر',
  'data-entry-draft-1',
  'aaaaaaaa-0000-0000-0000-0000000000d1'
) AS draft_id \gset
SELECT set_config('voya.test.ai_data_entry_draft_id', :'draft_id', false);

SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'اسم العميل أحمد ومعلومة غير مدعومة 150 متر',
  'data-entry-draft-1',
  'aaaaaaaa-0000-0000-0000-0000000000d2'
);

SELECT public.register_ai_data_entry_input_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'draft_id',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/cccccccc-cccc-cccc-cccc-cccccccccccc.png',
  'image/png',
  1024,
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'data-entry-input-1',
  'aaaaaaaa-0000-0000-0000-0000000000d3'
) AS input_id \gset
SELECT set_config('voya.test.ai_data_entry_input_id', :'input_id', false);

SELECT public.register_ai_data_entry_input_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'draft_id',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/cccccccc-cccc-cccc-cccc-cccccccccccc.png',
  'image/png',
  1024,
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'data-entry-input-1',
  'aaaaaaaa-0000-0000-0000-0000000000d4'
);

SELECT public.submit_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'draft_id',
  'data-entry-submit-1',
  'aaaaaaaa-0000-0000-0000-0000000000d5'
) AS run_id \gset
SELECT set_config('voya.test.ai_data_entry_run_id', :'run_id', false);

SELECT public.submit_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'draft_id',
  'data-entry-submit-1',
  'aaaaaaaa-0000-0000-0000-0000000000d6'
);

RESET ROLE;

SELECT id AS data_entry_event_id
FROM public.claim_outbox_delivery_events('ai-data-entry-test-worker', 20, 300)
WHERE event_type = 'ai.data_entry.requested'
  AND payload ->> 'run_id' = current_setting('voya.test.ai_data_entry_run_id')
LIMIT 1 \gset
SELECT set_config('voya.test.ai_data_entry_event_id', :'data_entry_event_id', false);

DO $$
DECLARE
  v_draft_status text;
  v_run_kind text;
  v_event_count integer;
  v_client_count integer;
  v_property_count integer;
BEGIN
  SELECT status INTO v_draft_status
  FROM public.ai_data_entry_drafts
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND id = current_setting('voya.test.ai_data_entry_draft_id')::uuid;
  SELECT agent_kind INTO v_run_kind FROM public.ai_runs WHERE id = current_setting('voya.test.ai_data_entry_run_id')::uuid;
  SELECT count(*) INTO v_event_count FROM public.outbox_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND event_type = 'ai.data_entry.requested' AND payload ->> 'run_id' = current_setting('voya.test.ai_data_entry_run_id');
  SELECT count(*) INTO v_client_count FROM public.clients WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND idempotency_key = 'data-entry-client-never-before-confirm';
  SELECT count(*) INTO v_property_count FROM public.properties WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND idempotency_key = 'data-entry-property-never-before-confirm';
  IF v_draft_status <> 'queued' OR v_run_kind <> 'data_entry' OR v_event_count <> 1 OR v_client_count <> 0 OR v_property_count <> 0 THEN
    RAISE EXCEPTION 'AI data-entry submission must queue a draft without writing source records';
  END IF;
END;
$$;

RESET ROLE;

SELECT public.mark_ai_run_started(current_setting('voya.test.ai_data_entry_event_id')::uuid, 'ai-data-entry-test-worker', 'extraction-test-model', 'data-entry-v1');
SELECT public.mark_ai_data_entry_extracting_v1(current_setting('voya.test.ai_data_entry_event_id')::uuid, 'ai-data-entry-test-worker');
SELECT public.mark_ai_data_entry_ready_v1(
  current_setting('voya.test.ai_data_entry_event_id')::uuid,
  'ai-data-entry-test-worker',
  '{"clients":[],"properties":[],"unresolved":[],"warnings":[]}'::jsonb
);
SELECT public.mark_ai_run_succeeded(
  current_setting('voya.test.ai_data_entry_event_id')::uuid,
  'ai-data-entry-test-worker',
  '{"provider":"fake","model":"extraction-test-model","output":"{}"}'::jsonb
);
SELECT public.complete_outbox_event(current_setting('voya.test.ai_data_entry_event_id')::uuid, 'ai-data-entry-test-worker');

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.mark_ai_data_entry_input_mapped_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.ai_data_entry_input_id')::uuid,
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-0000000000d9'
);
RESET ROLE;

UPDATE public.ai_data_entry_drafts
SET status = 'ready_for_review',
    extraction_payload = '{"clients":[{"displayName":"أحمد","phone":null,"whatsapp":null,"email":null,"nationality":null,"preferredLanguage":"ar","notes":null,"sourceLeadId":null,"confidence":"high","missingRequired":[]}],"properties":[],"unresolved":[],"warnings":[]}'::jsonb
WHERE id = current_setting('voya.test.ai_data_entry_draft_id')::uuid;
SELECT version AS ai_data_entry_ready_version
FROM public.ai_data_entry_drafts
WHERE id = current_setting('voya.test.ai_data_entry_draft_id')::uuid \gset

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.begin_ai_data_entry_confirmation_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.ai_data_entry_draft_id')::uuid,
  '{"clients":[{"displayName":"أحمد","phone":null,"whatsapp":null,"email":null,"nationality":null,"preferredLanguage":"ar","notes":null,"sourceLeadId":null,"confidence":"high","missingRequired":[]}],"properties":[],"unresolved":[],"warnings":[]}'::jsonb,
  :'ai_data_entry_ready_version',
  'data-entry-confirm-1',
  'aaaaaaaa-0000-0000-0000-0000000000d7'
);
RESET ROLE;

DO $$
DECLARE v_status text; v_client_count integer;
BEGIN
  SELECT status INTO v_status FROM public.ai_data_entry_drafts WHERE id = current_setting('voya.test.ai_data_entry_draft_id')::uuid;
  SELECT count(*) INTO v_client_count FROM public.clients WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND idempotency_key LIKE 'data-entry-client:%';
  IF v_status <> 'confirmed' OR v_client_count <> 0 THEN
    RAISE EXCEPTION 'confirmation must require deterministic writes and must not create a source record itself';
  END IF;
END;
$$;

SELECT version AS ai_data_entry_confirmed_version
FROM public.ai_data_entry_drafts
WHERE id = current_setting('voya.test.ai_data_entry_draft_id')::uuid \gset
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.record_ai_data_entry_progress_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.ai_data_entry_draft_id')::uuid,
  'applied',
  '{"clients":[],"properties":[],"images":[]}'::jsonb,
  :'ai_data_entry_confirmed_version',
  'data-entry-progress-1',
  'aaaaaaaa-0000-0000-0000-0000000000d8'
);
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.ai_data_entry_drafts WHERE id = current_setting('voya.test.ai_data_entry_draft_id')::uuid) <> 'applied' THEN
    RAISE EXCEPTION 'data-entry progress must close a fully applied draft';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.create_ai_data_entry_draft_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'viewer must be denied', 'data-entry-viewer-denied', NULL
    );
    RAISE EXCEPTION 'viewer must not create an AI data-entry draft';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

-- A same-tenant non-manager must not mutate another member's draft by UUID.
INSERT INTO auth.users (id)
VALUES ('77777777-7777-7777-7777-777777777777')
ON CONFLICT DO NOTHING;
INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '77777777-7777-7777-7777-777777777777', 'sales_agent', 'active')
ON CONFLICT (organization_id, user_id) DO UPDATE SET role = EXCLUDED.role, status = EXCLUDED.status;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'owner-only authorization probe', 'data-entry-authz-owner-draft', NULL
) AS authz_draft_id \gset
SELECT set_config('voya.test.authz_draft_id', :'authz_draft_id', false);
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '77777777-7777-7777-7777-777777777777', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.register_ai_data_entry_input_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.authz_draft_id')::uuid,
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/cccccccc-cccc-cccc-cccc-cccccccccccc.png',
      'image/png', 1024, NULL, 'data-entry-authz-input', NULL
    );
    RAISE EXCEPTION 'non-owner must not register input on another member draft';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.submit_ai_data_entry_draft_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.authz_draft_id')::uuid,
      'data-entry-authz-submit', NULL
    );
    RAISE EXCEPTION 'non-owner must not submit another member draft';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

UPDATE public.ai_data_entry_drafts
SET status = 'ready_for_review', extraction_payload = '{}'::jsonb, version = version + 1
WHERE id = current_setting('voya.test.authz_draft_id')::uuid;
SELECT version AS authz_ready_version FROM public.ai_data_entry_drafts
WHERE id = current_setting('voya.test.authz_draft_id')::uuid \gset
SELECT set_config('voya.test.authz_ready_version', :'authz_ready_version', false);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '77777777-7777-7777-7777-777777777777', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.begin_ai_data_entry_confirmation_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.authz_draft_id')::uuid,
      '{}'::jsonb, current_setting('voya.test.authz_ready_version')::integer, 'data-entry-authz-confirm', NULL
    );
    RAISE EXCEPTION 'non-owner must not confirm another member draft';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

UPDATE public.ai_data_entry_drafts
SET status = 'confirmed', confirmation_payload = '{}'::jsonb, confirmed_at = timezone('utc', now()),
    confirmed_by_membership_id = (
      SELECT owner_membership.id
      FROM public.organization_memberships AS owner_membership
      WHERE owner_membership.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND owner_membership.user_id = '11111111-1111-1111-1111-111111111111'
    ),
    version = version + 1
WHERE id = current_setting('voya.test.authz_draft_id')::uuid;
SELECT version AS authz_confirmed_version FROM public.ai_data_entry_drafts
WHERE id = current_setting('voya.test.authz_draft_id')::uuid \gset
SELECT set_config('voya.test.authz_confirmed_version', :'authz_confirmed_version', false);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '77777777-7777-7777-7777-777777777777', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.record_ai_data_entry_progress_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.authz_draft_id')::uuid,
      'applied', '{"probe":true}'::jsonb, current_setting('voya.test.authz_confirmed_version')::integer,
      'data-entry-authz-progress', NULL
    );
    RAISE EXCEPTION 'non-owner must not overwrite another member progress';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'owner-only rejection probe', 'data-entry-authz-reject-draft', NULL
) AS authz_reject_draft_id \gset
SELECT set_config('voya.test.authz_reject_draft_id', :'authz_reject_draft_id', false);
RESET ROLE;
SELECT version AS authz_reject_version FROM public.ai_data_entry_drafts
WHERE id = current_setting('voya.test.authz_reject_draft_id')::uuid \gset
SELECT set_config('voya.test.authz_reject_version', :'authz_reject_version', false);
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '77777777-7777-7777-7777-777777777777', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.reject_ai_data_entry_draft_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.authz_reject_draft_id')::uuid,
      current_setting('voya.test.authz_reject_version')::integer, 'data-entry-authz-reject', NULL
    );
    RAISE EXCEPTION 'non-owner must not reject another member draft';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'AI data-entry draft database tests passed' AS result;
