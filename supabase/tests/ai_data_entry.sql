-- Human-confirmed AI data-entry draft boundary checks.

DO $$
BEGIN
  IF to_regclass('public.ai_data_entry_drafts') IS NULL
    OR to_regclass('public.ai_data_entry_inputs') IS NULL
    OR to_regprocedure('public.create_ai_data_entry_draft_v1(uuid,text,text,uuid)') IS NULL
    OR to_regprocedure('public.register_ai_data_entry_input_v1(uuid,uuid,text,text,bigint,text,text,uuid)') IS NULL
    OR to_regprocedure('public.submit_ai_data_entry_draft_v1(uuid,uuid,text,uuid)') IS NULL
    OR to_regprocedure('public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid)') IS NULL
    OR to_regprocedure('public.heartbeat_ai_data_entry_confirmation_v3(uuid,uuid,uuid)') IS NULL
    OR to_regprocedure('public.archive_ai_data_entry_inputs_v1(uuid,uuid,uuid[],uuid)') IS NULL
    OR to_regprocedure('public.finalize_ai_data_entry_confirmation_v2(uuid,uuid,uuid,text,jsonb,integer,uuid)') IS NULL
    OR to_regprocedure('public.mark_ai_data_entry_input_mapped_v2(uuid,uuid,uuid,uuid,uuid,uuid)') IS NULL
    OR to_regprocedure('public.finalize_ai_data_entry_extraction_v1(uuid,text,jsonb,jsonb)') IS NULL
    OR to_regprocedure('public.finalize_ai_data_entry_failure_v1(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'AI data-entry hardened boundary is missing';
  END IF;

  IF has_table_privilege('authenticated', 'public.ai_data_entry_drafts', 'INSERT')
    OR has_table_privilege('authenticated', 'public.ai_data_entry_inputs', 'INSERT') THEN
    RAISE EXCEPTION 'browser role must use AI data-entry RPCs, not direct table writes';
  END IF;
  IF has_function_privilege('anon', 'public.create_ai_data_entry_draft_v1(uuid,text,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not create AI data-entry drafts';
  END IF;
  IF has_function_privilege('authenticated', 'public.claim_ai_data_entry_confirmation_v2(uuid,uuid,jsonb,integer,text,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated operators must use the durable v3 confirmation claim';
  END IF;
  IF has_function_privilege('authenticated', 'public.heartbeat_ai_data_entry_confirmation_v3(uuid,uuid,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.archive_ai_data_entry_inputs_v1(uuid,uuid,uuid[],uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.finalize_ai_data_entry_confirmation_v2(uuid,uuid,uuid,text,jsonb,integer,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.mark_ai_data_entry_input_mapped_v2(uuid,uuid,uuid,uuid,uuid,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.record_ai_data_entry_progress_v1(uuid,uuid,text,jsonb,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.mark_ai_data_entry_input_mapped_v1(uuid,uuid,uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'browser role must not assert trusted application progress, cleanup, or image mapping';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.heartbeat_ai_data_entry_confirmation_v3(uuid,uuid,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.archive_ai_data_entry_inputs_v1(uuid,uuid,uuid[],uuid)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.finalize_ai_data_entry_confirmation_v2(uuid,uuid,uuid,text,jsonb,integer,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.mark_ai_data_entry_input_mapped_v2(uuid,uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service role must own trusted confirmation finalization and cleanup';
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

-- Draft creation is idempotent for the same source payload.
SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'اسم العميل أحمد ومعلومة غير مدعومة 150 متر',
  'data-entry-draft-1',
  'aaaaaaaa-0000-0000-0000-0000000000d2'
);

SELECT public.register_ai_data_entry_input_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'draft_id',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || :'draft_id' || '/cccccccc-cccc-cccc-cccc-cccccccccccc.png',
  'image/png',
  1024,
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'data-entry-input-1',
  'aaaaaaaa-0000-0000-0000-0000000000d3'
) AS input_id \gset
SELECT set_config('voya.test.ai_data_entry_input_id', :'input_id', false);

DO $$
BEGIN
  BEGIN
    PERFORM public.register_ai_data_entry_input_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.ai_data_entry_draft_id')::uuid,
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/' || current_setting('voya.test.ai_data_entry_draft_id') || '/dddddddd-dddd-dddd-dddd-dddddddddddd.png',
      'image/png', 1024, NULL, 'data-entry-wrong-organization-path', NULL
    );
    RAISE EXCEPTION 'input path from another organization must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.register_ai_data_entry_input_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.ai_data_entry_draft_id')::uuid,
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee/dddddddd-dddd-dddd-dddd-dddddddddddd.png',
      'image/png', 1024, NULL, 'data-entry-wrong-draft-path', NULL
    );
    RAISE EXCEPTION 'input path from another draft must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END;
$$;

-- Input registration is idempotent only when all immutable metadata matches.
SELECT public.register_ai_data_entry_input_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'draft_id',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || :'draft_id' || '/cccccccc-cccc-cccc-cccc-cccccccccccc.png',
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
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND id = current_setting('voya.test.ai_data_entry_draft_id')::uuid;
  SELECT agent_kind INTO v_run_kind
  FROM public.ai_runs WHERE id = current_setting('voya.test.ai_data_entry_run_id')::uuid;
  SELECT count(*) INTO v_event_count
  FROM public.outbox_events
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND event_type = 'ai.data_entry.requested'
    AND payload ->> 'run_id' = current_setting('voya.test.ai_data_entry_run_id');
  SELECT count(*) INTO v_client_count
  FROM public.clients
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND idempotency_key = 'data-entry-client-never-before-confirm';
  SELECT count(*) INTO v_property_count
  FROM public.properties
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND idempotency_key = 'data-entry-property-never-before-confirm';
  IF v_draft_status <> 'queued' OR v_run_kind <> 'data_entry' OR v_event_count <> 1
    OR v_client_count <> 0 OR v_property_count <> 0 THEN
    RAISE EXCEPTION 'AI data-entry submission must queue a draft without writing source records';
  END IF;
END;
$$;

-- Worker success is one atomic transition: run succeeded + draft ready.
SELECT public.mark_ai_run_started(
  current_setting('voya.test.ai_data_entry_event_id')::uuid,
  'ai-data-entry-test-worker',
  'extraction-test-model',
  'data-entry-v1'
);
SELECT public.mark_ai_data_entry_extracting_v1(
  current_setting('voya.test.ai_data_entry_event_id')::uuid,
  'ai-data-entry-test-worker'
);
SELECT public.finalize_ai_data_entry_extraction_v1(
  current_setting('voya.test.ai_data_entry_event_id')::uuid,
  'ai-data-entry-test-worker',
  '{"clients":[{"displayName":"أحمد","phone":null,"whatsapp":null,"email":null,"nationality":null,"preferredLanguage":"ar","notes":null,"sourceLeadId":null,"confidence":"high","missingRequired":[]}],"properties":[],"unresolved":[],"warnings":[]}'::jsonb,
  '{"provider":"fake","model":"extraction-test-model","output":"{}"}'::jsonb
);
SELECT public.complete_outbox_event(
  current_setting('voya.test.ai_data_entry_event_id')::uuid,
  'ai-data-entry-test-worker'
);

DO $$
DECLARE v_draft_status text; v_run_status text;
BEGIN
  SELECT status INTO v_draft_status FROM public.ai_data_entry_drafts
  WHERE id = current_setting('voya.test.ai_data_entry_draft_id')::uuid;
  SELECT status INTO v_run_status FROM public.ai_runs
  WHERE id = current_setting('voya.test.ai_data_entry_run_id')::uuid;
  IF v_draft_status <> 'ready_for_review' OR v_run_status <> 'succeeded' THEN
    RAISE EXCEPTION 'data-entry worker finalization must transition run and draft together';
  END IF;
END;
$$;

SELECT version AS ai_data_entry_ready_version
FROM public.ai_data_entry_drafts
WHERE id = current_setting('voya.test.ai_data_entry_draft_id')::uuid \gset

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT outcome AS claim_outcome, execution_token AS claim_token, draft_version AS claimed_version
FROM public.claim_ai_data_entry_confirmation_v3(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.ai_data_entry_draft_id')::uuid,
  '{"clients":[{"displayName":"أحمد","phone":null,"whatsapp":null,"email":null,"nationality":null,"preferredLanguage":"ar","notes":null,"sourceLeadId":null,"confidence":"high","missingRequired":[]}],"properties":[],"unresolved":[],"warnings":[]}'::jsonb,
  ARRAY[]::integer[],
  ARRAY[]::integer[],
  :'ai_data_entry_ready_version',
  'data-entry-confirm-1',
  'aaaaaaaa-0000-0000-0000-0000000000d7'
) \gset
SELECT set_config('voya.test.ai_data_entry_claim_token', :'claim_token', false);
SELECT set_config('voya.test.ai_data_entry_claimed_version', :'claimed_version', false);
RESET ROLE;

DO $$
DECLARE v_status text; v_client_count integer;
BEGIN
  SELECT status INTO v_status FROM public.ai_data_entry_drafts
  WHERE id = current_setting('voya.test.ai_data_entry_draft_id')::uuid;
  SELECT count(*) INTO v_client_count FROM public.clients
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND idempotency_key LIKE 'data-entry-client:%';
  IF current_setting('voya.test.ai_data_entry_claim_token') = ''
    OR v_status <> 'confirmed' OR v_client_count <> 0 THEN
    RAISE EXCEPTION 'human confirmation may claim execution but must not write source records itself';
  END IF;
END;
$$;

-- Only the trusted service boundary can archive unused private inputs and record application progress.
SET ROLE service_role;
SELECT public.archive_ai_data_entry_inputs_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.ai_data_entry_draft_id')::uuid,
  ARRAY[current_setting('voya.test.ai_data_entry_input_id')::uuid],
  current_setting('voya.test.ai_data_entry_claim_token')::uuid
);
-- Archiving is idempotent so storage cleanup can be retried independently.
SELECT public.archive_ai_data_entry_inputs_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.ai_data_entry_draft_id')::uuid,
  ARRAY[current_setting('voya.test.ai_data_entry_input_id')::uuid],
  current_setting('voya.test.ai_data_entry_claim_token')::uuid
);
SELECT public.finalize_ai_data_entry_confirmation_v2(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.ai_data_entry_draft_id')::uuid,
  current_setting('voya.test.ai_data_entry_claim_token')::uuid,
  'applied',
  '{"clients":[],"properties":[],"images":[]}'::jsonb,
  current_setting('voya.test.ai_data_entry_claimed_version')::integer,
  'aaaaaaaa-0000-0000-0000-0000000000d8'
);
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.ai_data_entry_drafts
      WHERE id = current_setting('voya.test.ai_data_entry_draft_id')::uuid) <> 'applied'
    OR (SELECT status FROM public.ai_data_entry_inputs
      WHERE id = current_setting('voya.test.ai_data_entry_input_id')::uuid) <> 'archived' THEN
    RAISE EXCEPTION 'trusted data-entry cleanup and finalization must close a fully applied draft';
  END IF;
END;
$$;

-- Expiry is durable: the RPC returns without raising, so the state update commits.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'expired draft probe',
  'data-entry-expired-draft',
  NULL
) AS expired_draft_id \gset
SELECT set_config('voya.test.ai_data_entry_expired_draft_id', :'expired_draft_id', false);
RESET ROLE;
UPDATE public.ai_data_entry_drafts
SET expires_at = timezone('utc', now()) - interval '1 minute'
WHERE id = :'expired_draft_id';
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.submit_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'expired_draft_id',
  'data-entry-expired-submit',
  NULL
);
RESET ROLE;
DO $$
BEGIN
  IF (SELECT status FROM public.ai_data_entry_drafts
      WHERE id = current_setting('voya.test.ai_data_entry_expired_draft_id')::uuid) <> 'expired' THEN
    RAISE EXCEPTION 'expired draft state must survive the command boundary';
  END IF;
END;
$$;

-- Viewer cannot enter the workflow.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.create_ai_data_entry_draft_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'viewer must be denied', 'data-entry-viewer-denied', NULL
    );
    RAISE EXCEPTION 'viewer must not create an AI data-entry draft';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
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
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || current_setting('voya.test.authz_draft_id') || '/cccccccc-cccc-cccc-cccc-cccccccccccc.png',
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
    PERFORM public.claim_ai_data_entry_confirmation_v3(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.authz_draft_id')::uuid,
      '{"clients":[],"properties":[],"unresolved":[],"warnings":[]}'::jsonb,
      ARRAY[]::integer[], ARRAY[]::integer[],
      current_setting('voya.test.authz_ready_version')::integer, 'data-entry-authz-confirm', NULL
    );
    RAISE EXCEPTION 'non-owner must not confirm another member draft';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM public.finalize_ai_data_entry_confirmation_v2(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.authz_draft_id')::uuid,
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'applied', '{}'::jsonb,
      current_setting('voya.test.authz_ready_version')::integer, NULL
    );
    RAISE EXCEPTION 'authenticated role must not call trusted finalization';
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

SELECT 'AI data-entry hardened database tests passed' AS result;