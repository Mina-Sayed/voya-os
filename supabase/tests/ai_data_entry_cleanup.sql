-- Regression proofs for terminal AI data-entry input cleanup and replay safety.

DO $$
BEGIN
  IF to_regprocedure('public.archive_ai_data_entry_inputs_v1(uuid,uuid,uuid[],uuid)') IS NULL
    OR to_regprocedure('public.finalize_ai_data_entry_failure_v1(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'AI data-entry cleanup boundary is missing';
  END IF;
END;
$$;

-- Expiring a collecting draft must archive active input metadata atomically.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '',
  'cleanup-expired-draft',
  NULL
) AS cleanup_expired_draft_id \gset
SELECT public.register_ai_data_entry_input_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'cleanup_expired_draft_id',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || :'cleanup_expired_draft_id' || '/11111111-2222-4333-8444-555555555555.png',
  'image/png',
  128,
  '1111111111111111111111111111111111111111111111111111111111111111',
  'cleanup-expired-input',
  NULL
) AS cleanup_expired_input_id \gset
RESET ROLE;
SELECT set_config('voya.test.cleanup_expired_draft_id', :'cleanup_expired_draft_id', false);
SELECT set_config('voya.test.cleanup_expired_input_id', :'cleanup_expired_input_id', false);

UPDATE public.ai_data_entry_drafts
SET expires_at = timezone('utc', now()) - interval '1 minute'
WHERE id = current_setting('voya.test.cleanup_expired_draft_id')::uuid;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.submit_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.cleanup_expired_draft_id')::uuid,
  'cleanup-expired-submit',
  NULL
);
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.ai_data_entry_drafts
      WHERE id = current_setting('voya.test.cleanup_expired_draft_id')::uuid) <> 'expired'
    OR (SELECT status FROM public.ai_data_entry_inputs
      WHERE id = current_setting('voya.test.cleanup_expired_input_id')::uuid) <> 'archived' THEN
    RAISE EXCEPTION 'expired drafts must archive active input metadata';
  END IF;
END;
$$;

-- A terminal draft must not accept an idempotent replay of the old upload.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.register_ai_data_entry_input_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.cleanup_expired_draft_id')::uuid,
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || current_setting('voya.test.cleanup_expired_draft_id') || '/11111111-2222-4333-8444-555555555555.png',
      'image/png',
      128,
      '1111111111111111111111111111111111111111111111111111111111111111',
      'cleanup-expired-input',
      NULL
    );
    RAISE EXCEPTION 'terminal draft replay must be rejected';
  EXCEPTION WHEN serialization_failure THEN NULL;
  END;
END;
$$;
RESET ROLE;

-- Rejection is allowed only after extraction reaches human review, and the
-- terminal state must archive active input metadata atomically.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '',
  'cleanup-rejected-draft',
  NULL
) AS cleanup_rejected_draft_id \gset
SELECT public.register_ai_data_entry_input_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'cleanup_rejected_draft_id',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || :'cleanup_rejected_draft_id' || '/66666666-7777-4888-8999-000000000000.png',
  'image/png',
  128,
  '2222222222222222222222222222222222222222222222222222222222222222',
  'cleanup-rejected-input',
  NULL
) AS cleanup_rejected_input_id \gset
RESET ROLE;
SELECT set_config('voya.test.cleanup_rejected_draft_id', :'cleanup_rejected_draft_id', false);
SELECT set_config('voya.test.cleanup_rejected_input_id', :'cleanup_rejected_input_id', false);

UPDATE public.ai_data_entry_drafts
SET status = 'ready_for_review',
    extraction_payload = '{"clients":[],"properties":[],"unresolved":[],"warnings":[]}'::jsonb,
    version = version + 1
WHERE id = current_setting('voya.test.cleanup_rejected_draft_id')::uuid;
SELECT version AS cleanup_rejected_version
FROM public.ai_data_entry_drafts
WHERE id = current_setting('voya.test.cleanup_rejected_draft_id')::uuid \gset

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.reject_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.cleanup_rejected_draft_id')::uuid,
  :'cleanup_rejected_version',
  'cleanup-rejected-command',
  NULL
);
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.ai_data_entry_drafts
      WHERE id = current_setting('voya.test.cleanup_rejected_draft_id')::uuid) <> 'rejected'
    OR (SELECT status FROM public.ai_data_entry_inputs
      WHERE id = current_setting('voya.test.cleanup_rejected_input_id')::uuid) <> 'archived' THEN
    RAISE EXCEPTION 'rejected drafts must archive active input metadata';
  END IF;
END;
$$;

-- A collecting draft cannot be rejected directly through the authenticated RPC.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'not reviewable yet',
  'cleanup-reject-state-guard',
  NULL
) AS cleanup_guard_draft_id \gset
SELECT version AS cleanup_guard_version
FROM public.ai_data_entry_drafts WHERE id = :'cleanup_guard_draft_id' \gset
SELECT set_config('voya.test.cleanup_guard_draft_id', :'cleanup_guard_draft_id', false);
SELECT set_config('voya.test.cleanup_guard_version', :'cleanup_guard_version', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.reject_ai_data_entry_draft_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.cleanup_guard_draft_id')::uuid,
      current_setting('voya.test.cleanup_guard_version')::integer,
      'cleanup-reject-state-guard-command',
      NULL
    );
    RAISE EXCEPTION 'collecting draft rejection must be rejected';
  EXCEPTION WHEN serialization_failure THEN NULL;
  END;
END;
$$;
RESET ROLE;

-- Expiry discovered while claiming a review must archive remaining private inputs.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '',
  'cleanup-claim-expired-draft',
  NULL
) AS cleanup_claim_expired_draft_id \gset
SELECT public.register_ai_data_entry_input_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'cleanup_claim_expired_draft_id',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || :'cleanup_claim_expired_draft_id' || '/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.png',
  'image/png',
  128,
  '3333333333333333333333333333333333333333333333333333333333333333',
  'cleanup-claim-expired-input',
  NULL
) AS cleanup_claim_expired_input_id \gset
RESET ROLE;
SELECT set_config('voya.test.cleanup_claim_expired_draft_id', :'cleanup_claim_expired_draft_id', false);
SELECT set_config('voya.test.cleanup_claim_expired_input_id', :'cleanup_claim_expired_input_id', false);

UPDATE public.ai_data_entry_drafts
SET status = 'ready_for_review',
    expires_at = timezone('utc', now()) - interval '1 minute',
    version = version + 1
WHERE id = current_setting('voya.test.cleanup_claim_expired_draft_id')::uuid;
SELECT version AS cleanup_claim_expired_version
FROM public.ai_data_entry_drafts
WHERE id = current_setting('voya.test.cleanup_claim_expired_draft_id')::uuid \gset

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT outcome AS cleanup_claim_outcome
FROM public.claim_ai_data_entry_confirmation_v3(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.cleanup_claim_expired_draft_id')::uuid,
  '{"clients":[],"properties":[]}'::jsonb,
  ARRAY[]::integer[],
  ARRAY[]::integer[],
  :'cleanup_claim_expired_version',
  'cleanup-claim-expired-command',
  NULL
) \gset
RESET ROLE;
SELECT set_config('voya.test.cleanup_claim_outcome', :'cleanup_claim_outcome', false);

DO $$
BEGIN
  IF current_setting('voya.test.cleanup_claim_outcome') <> 'expired'
    OR (SELECT status FROM public.ai_data_entry_drafts
      WHERE id = current_setting('voya.test.cleanup_claim_expired_draft_id')::uuid) <> 'expired'
    OR (SELECT status FROM public.ai_data_entry_inputs
      WHERE id = current_setting('voya.test.cleanup_claim_expired_input_id')::uuid) <> 'archived' THEN
    RAISE EXCEPTION 'expired confirmation claims must return expired and archive active input metadata';
  END IF;
END;
$$;

-- Outbound provider lease assertions are isolated so no shared outbox state
-- leaks into the later database/race suites.
BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.renew_outbox_delivery_lease_v1(uuid,text,integer)') IS NULL THEN
    RAISE EXCEPTION 'outbound delivery lease renewal function is missing';
  END IF;
  IF has_function_privilege('authenticated', 'public.renew_outbox_delivery_lease_v1(uuid,text,integer)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.renew_outbox_delivery_lease_v1(uuid,text,integer)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.renew_outbox_delivery_lease_v1(uuid,text,integer)', 'EXECUTE')
    OR NOT has_function_privilege('voya_outbox_worker', 'public.renew_outbox_delivery_lease_v1(uuid,text,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'outbound delivery lease renewal must remain worker/service-only';
  END IF;
END;
$$;

UPDATE public.outbox_events
SET available_at = timezone('utc', now()) + interval '1 hour',
    locked_until = CASE WHEN state = 'processing' THEN timezone('utc', now()) + interval '1 hour' ELSE NULL END
WHERE state IN ('pending', 'retry_wait', 'processing');

INSERT INTO public.outbox_events (
  organization_id, event_type, schema_version, dedupe_key, payload
) VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'whatsapp.message.send_requested',
  1,
  'outbound-lease-revalidation-test',
  '{}'::jsonb
);

SELECT id AS outbound_lease_event_id
FROM public.claim_outbox_delivery_events('outbound-lease-worker-a', 20, 30)
WHERE dedupe_key = 'outbound-lease-revalidation-test'
LIMIT 1 \gset
SELECT set_config('voya.test.outbound_lease_event_id', :'outbound_lease_event_id', true);

SET ROLE service_role;
SELECT public.renew_outbox_delivery_lease_v1(
  current_setting('voya.test.outbound_lease_event_id')::uuid,
  'outbound-lease-worker-a',
  300
) AS outbound_owner_renewed \gset
RESET ROLE;
SELECT set_config('voya.test.outbound_owner_renewed', :'outbound_owner_renewed', true);

DO $$
BEGIN
  IF current_setting('voya.test.outbound_owner_renewed') <> 't'
    OR (SELECT locked_until FROM public.outbox_events
        WHERE id = current_setting('voya.test.outbound_lease_event_id')::uuid) <= timezone('utc', now()) + interval '4 minutes' THEN
    RAISE EXCEPTION 'the current outbound worker must be able to renew its live lease';
  END IF;
END;
$$;

UPDATE public.outbox_events
SET locked_by = 'outbound-lease-worker-b',
    locked_until = timezone('utc', now()) + interval '30 seconds',
    attempts = attempts + 1
WHERE id = current_setting('voya.test.outbound_lease_event_id')::uuid;

SET ROLE service_role;
SELECT public.renew_outbox_delivery_lease_v1(
  current_setting('voya.test.outbound_lease_event_id')::uuid,
  'outbound-lease-worker-a',
  300
) AS outbound_stale_renewed \gset
SELECT public.renew_outbox_delivery_lease_v1(
  current_setting('voya.test.outbound_lease_event_id')::uuid,
  'outbound-lease-worker-b',
  300
) AS outbound_replacement_renewed \gset
RESET ROLE;
SELECT set_config('voya.test.outbound_stale_renewed', :'outbound_stale_renewed', true);
SELECT set_config('voya.test.outbound_replacement_renewed', :'outbound_replacement_renewed', true);

DO $$
BEGIN
  IF current_setting('voya.test.outbound_stale_renewed') <> 'f'
    OR current_setting('voya.test.outbound_replacement_renewed') <> 't'
    OR (SELECT locked_until FROM public.outbox_events
        WHERE id = current_setting('voya.test.outbound_lease_event_id')::uuid) <= timezone('utc', now()) + interval '4 minutes' THEN
    RAISE EXCEPTION 'only the replacement owner may renew a reclaimed outbound delivery lease';
  END IF;
END;
$$;

ROLLBACK;

SELECT 'AI data-entry cleanup and provider lease tests passed' AS result;