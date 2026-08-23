-- Regression proofs for AI data-entry recovery, claim durability, and worker retries.

DO $$
BEGIN
  IF to_regprocedure('public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid)') IS NULL
    OR to_regprocedure('public.heartbeat_ai_data_entry_confirmation_v3(uuid,uuid,uuid)') IS NULL
    OR to_regprocedure('public.finalize_ai_data_entry_failure_v1(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'AI data-entry recovery hardening functions are missing';
  END IF;

  IF has_function_privilege('authenticated', 'public.claim_ai_data_entry_confirmation_v2(uuid,uuid,jsonb,integer,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated callers must not bypass the durable exclusion claim';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated operators must use the v3 confirmation claim';
  END IF;
  IF has_function_privilege('authenticated', 'public.heartbeat_ai_data_entry_confirmation_v3(uuid,uuid,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.heartbeat_ai_data_entry_confirmation_v3(uuid,uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'confirmation heartbeats must be service-only';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'recovery claim probe',
  'data-entry-recovery-claim',
  NULL
) AS recovery_draft_id \gset
RESET ROLE;

UPDATE public.ai_data_entry_drafts
SET status = 'ready_for_review',
    extraction_payload = '{"clients":[],"properties":[],"unresolved":[],"warnings":[]}'::jsonb,
    version = version + 1
WHERE id = :'recovery_draft_id';
SELECT version AS recovery_ready_version
FROM public.ai_data_entry_drafts
WHERE id = :'recovery_draft_id' \gset

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT outcome AS recovery_claim_outcome,
       execution_token AS recovery_claim_token,
       draft_version AS recovery_claimed_version
FROM public.claim_ai_data_entry_confirmation_v3(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'recovery_draft_id',
  '{"clients":[{"displayName":"keep","phone":null,"whatsapp":null,"email":null,"nationality":null,"preferredLanguage":null,"notes":null,"sourceLeadId":null,"confidence":"high","missingRequired":[]},{"displayName":"exclude","phone":null,"whatsapp":null,"email":null,"nationality":null,"preferredLanguage":null,"notes":null,"sourceLeadId":null,"confidence":"high","missingRequired":[]}],"properties":[{"code":"REC-1","name":"exclude property","timezone":"Africa/Cairo","address":null,"city":null,"unitLabel":null,"bedrooms":null,"maxGuests":null,"operationalNotes":null,"imageInputIds":[],"confidence":"high","missingRequired":[]}],"unresolved":[],"warnings":[]}'::jsonb,
  ARRAY[1]::integer[],
  ARRAY[0]::integer[],
  :'recovery_ready_version',
  'data-entry-recovery-confirm-1',
  NULL
) \gset
RESET ROLE;

SELECT set_config('voya.test.recovery_draft_id', :'recovery_draft_id', false);
SELECT set_config('voya.test.recovery_claim_token', :'recovery_claim_token', false);
SELECT set_config('voya.test.recovery_claimed_version', :'recovery_claimed_version', false);

DO $$
DECLARE v_result jsonb; v_heartbeat timestamptz;
BEGIN
  SELECT application_result, confirmation_execution_heartbeat_at
    INTO v_result, v_heartbeat
  FROM public.ai_data_entry_drafts
  WHERE id = current_setting('voya.test.recovery_draft_id')::uuid;

  IF v_heartbeat IS NULL
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(coalesce(v_result -> 'clients', '[]'::jsonb)) AS item
      WHERE item ->> 'index' = '1' AND item ->> 'errorCode' = 'excluded_by_operator'
    )
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(coalesce(v_result -> 'properties', '[]'::jsonb)) AS item
      WHERE item ->> 'index' = '0' AND item ->> 'errorCode' = 'excluded_by_operator'
    ) THEN
    RAISE EXCEPTION 'confirmation claim must atomically persist operator exclusions and heartbeat';
  END IF;
END;
$$;

-- A stale claimed_at timestamp alone must not permit reclaim while the trusted heartbeat is current.
UPDATE public.ai_data_entry_drafts
SET confirmation_execution_claimed_at = timezone('utc', now()) - interval '40 minutes'
WHERE id = current_setting('voya.test.recovery_draft_id')::uuid;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT outcome AS heartbeat_guard_outcome
FROM public.claim_ai_data_entry_confirmation_v3(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.recovery_draft_id')::uuid,
  '{"clients":[{"displayName":"keep","phone":null,"whatsapp":null,"email":null,"nationality":null,"preferredLanguage":null,"notes":null,"sourceLeadId":null,"confidence":"high","missingRequired":[]},{"displayName":"exclude","phone":null,"whatsapp":null,"email":null,"nationality":null,"preferredLanguage":null,"notes":null,"sourceLeadId":null,"confidence":"high","missingRequired":[]}],"properties":[{"code":"REC-1","name":"exclude property","timezone":"Africa/Cairo","address":null,"city":null,"unitLabel":null,"bedrooms":null,"maxGuests":null,"operationalNotes":null,"imageInputIds":[],"confidence":"high","missingRequired":[]}],"unresolved":[],"warnings":[]}'::jsonb,
  ARRAY[1]::integer[], ARRAY[0]::integer[],
  current_setting('voya.test.recovery_claimed_version')::integer,
  'data-entry-recovery-confirm-2', NULL
) \gset
RESET ROLE;
SELECT set_config('voya.test.heartbeat_guard_outcome', :'heartbeat_guard_outcome', false);

DO $$ BEGIN
  IF current_setting('voya.test.heartbeat_guard_outcome') <> 'in_progress' THEN
    RAISE EXCEPTION 'a live heartbeat must prevent confirmation reclaim';
  END IF;
END $$;

-- Once the heartbeat itself is stale, a new execution may safely reclaim the draft.
UPDATE public.ai_data_entry_drafts
SET confirmation_execution_heartbeat_at = timezone('utc', now()) - interval '40 minutes'
WHERE id = current_setting('voya.test.recovery_draft_id')::uuid;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT outcome AS stale_reclaim_outcome,
       execution_token AS stale_reclaim_token
FROM public.claim_ai_data_entry_confirmation_v3(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.recovery_draft_id')::uuid,
  '{"clients":[{"displayName":"keep","phone":null,"whatsapp":null,"email":null,"nationality":null,"preferredLanguage":null,"notes":null,"sourceLeadId":null,"confidence":"high","missingRequired":[]},{"displayName":"exclude","phone":null,"whatsapp":null,"email":null,"nationality":null,"preferredLanguage":null,"notes":null,"sourceLeadId":null,"confidence":"high","missingRequired":[]}],"properties":[{"code":"REC-1","name":"exclude property","timezone":"Africa/Cairo","address":null,"city":null,"unitLabel":null,"bedrooms":null,"maxGuests":null,"operationalNotes":null,"imageInputIds":[],"confidence":"high","missingRequired":[]}],"unresolved":[],"warnings":[]}'::jsonb,
  ARRAY[1]::integer[], ARRAY[0]::integer[],
  current_setting('voya.test.recovery_claimed_version')::integer,
  'data-entry-recovery-confirm-3', NULL
) \gset
RESET ROLE;
SELECT set_config('voya.test.stale_reclaim_outcome', :'stale_reclaim_outcome', false);
SELECT set_config('voya.test.stale_reclaim_token', :'stale_reclaim_token', false);

DO $$ BEGIN
  IF current_setting('voya.test.stale_reclaim_outcome') <> 'claimed'
    OR current_setting('voya.test.stale_reclaim_token') = current_setting('voya.test.recovery_claim_token') THEN
    RAISE EXCEPTION 'a genuinely stale heartbeat must permit a fresh execution token';
  END IF;
END $$;

-- Worker retry: an already-extracting draft must accept the next delivery attempt idempotently.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'worker retry probe',
  'data-entry-recovery-worker',
  NULL
) AS worker_draft_id \gset
SELECT public.submit_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'worker_draft_id',
  'data-entry-recovery-worker-submit',
  NULL
) AS worker_run_id \gset
RESET ROLE;

SELECT id AS worker_event_id
FROM public.claim_outbox_delivery_events('ai-data-entry-recovery-worker', 20, 300)
WHERE event_type = 'ai.data_entry.requested' AND payload ->> 'run_id' = :'worker_run_id'
LIMIT 1 \gset

SELECT public.mark_ai_run_started(:'worker_event_id', 'ai-data-entry-recovery-worker', 'recovery-model', 'data-entry-v1');
SELECT public.mark_ai_data_entry_extracting_v1(:'worker_event_id', 'ai-data-entry-recovery-worker') AS first_extracting \gset
SELECT version AS extracting_version
FROM public.ai_data_entry_drafts WHERE id = :'worker_draft_id' \gset
SELECT public.mark_ai_data_entry_extracting_v1(:'worker_event_id', 'ai-data-entry-recovery-worker') AS retry_extracting \gset
SELECT set_config('voya.test.worker_draft_id', :'worker_draft_id', false);
SELECT set_config('voya.test.worker_run_id', :'worker_run_id', false);
SELECT set_config('voya.test.worker_event_id', :'worker_event_id', false);
SELECT set_config('voya.test.first_extracting', :'first_extracting', false);
SELECT set_config('voya.test.retry_extracting', :'retry_extracting', false);
SELECT set_config('voya.test.extracting_version', :'extracting_version', false);

DO $$
DECLARE v_version integer;
BEGIN
  SELECT version INTO v_version FROM public.ai_data_entry_drafts WHERE id = current_setting('voya.test.worker_draft_id')::uuid;
  IF current_setting('voya.test.first_extracting') <> 't'
    OR current_setting('voya.test.retry_extracting') <> 't'
    OR v_version <> current_setting('voya.test.extracting_version')::integer THEN
    RAISE EXCEPTION 'extracting transition must be idempotent across provider retries';
  END IF;
END;
$$;

SELECT public.finalize_ai_data_entry_failure_v1(
  current_setting('voya.test.worker_event_id')::uuid,
  'ai-data-entry-recovery-worker',
  'ai_provider_invalid_response'
) AS terminalized_failure \gset
SELECT set_config('voya.test.terminalized_failure', :'terminalized_failure', false);

DO $$
DECLARE v_draft_status text; v_run_status text;
BEGIN
  SELECT status INTO v_draft_status FROM public.ai_data_entry_drafts WHERE id = current_setting('voya.test.worker_draft_id')::uuid;
  SELECT status INTO v_run_status FROM public.ai_runs WHERE id = current_setting('voya.test.worker_run_id')::uuid;
  IF current_setting('voya.test.terminalized_failure') <> 't'
    OR v_draft_status <> 'failed' OR v_run_status <> 'failed' THEN
    RAISE EXCEPTION 'permanent data-entry failure must terminalize run and draft together';
  END IF;
END;
$$;
