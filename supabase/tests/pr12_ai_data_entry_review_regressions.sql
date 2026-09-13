-- PR #12 regression proofs for the remaining AI data-entry review findings.
\set ON_ERROR_STOP on

INSERT INTO public.ai_runs (
  id, organization_id, agent_kind, agent_version, status, purpose, model_name,
  prompt_version, initiated_by_membership_id, idempotency_key, result_summary
)
SELECT
  'aaaaaaaa-0000-4000-8000-00000000b101'::uuid,
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  'data_entry', 'registry-v1', 'succeeded', 'PR12 AAL2 result probe',
  'test-model', 'data-entry-v1', membership.id, 'pr12-aal2-result-probe',
  '{"provider":"gemini","model":"test-model","output":"sensitive extracted payload"}'::jsonb
FROM public.organization_memberships AS membership
WHERE membership.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND membership.user_id = '11111111-1111-1111-1111-111111111111'
ON CONFLICT (id) DO UPDATE SET result_summary = EXCLUDED.result_summary, status = 'succeeded';

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal1', false);
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.get_ai_run_result_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-4000-8000-00000000b101'
    );
    RAISE EXCEPTION 'AAL1 must not read a data-entry result through the generic AI result RPC';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

INSERT INTO public.ai_runs (
  id, organization_id, agent_kind, agent_version, status, purpose, model_name,
  prompt_version, initiated_by_membership_id, idempotency_key
)
SELECT
  'aaaaaaaa-0000-4000-8000-00000000b111'::uuid,
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  'data_entry', 'registry-v1', 'queued', 'PR12 submitter revalidation probe',
  'unconfigured', 'unconfigured', membership.id, 'pr12-submitter-revalidation'
FROM public.organization_memberships AS membership
WHERE membership.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND membership.user_id = '11111111-1111-1111-1111-111111111111'
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.ai_data_entry_drafts (
  id, organization_id, created_by_membership_id, source_text, source_kind,
  idempotency_key, status, ai_run_id, submit_idempotency_key
)
SELECT
  'aaaaaaaa-0000-4000-8000-00000000b112'::uuid,
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  membership.id, 'private customer intake', 'text',
  'pr12-submitter-draft', 'queued',
  'aaaaaaaa-0000-4000-8000-00000000b111'::uuid,
  'pr12-submitter-submit'
FROM public.organization_memberships AS membership
WHERE membership.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND membership.user_id = '11111111-1111-1111-1111-111111111111'
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.outbox_events (
  id, organization_id, event_type, schema_version, dedupe_key, payload,
  state, attempts, locked_by, locked_until
) VALUES (
  'aaaaaaaa-0000-4000-8000-00000000b113',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'ai.data_entry.requested', 1, 'pr12-submitter-event',
  '{"run_id":"aaaaaaaa-0000-4000-8000-00000000b111","draft_id":"aaaaaaaa-0000-4000-8000-00000000b112","agent_kind":"data_entry"}'::jsonb,
  'processing', 1, 'pr12-review-worker', timezone('utc', now()) + interval '5 minutes'
) ON CONFLICT (id) DO UPDATE
SET state = 'processing', locked_by = 'pr12-review-worker', locked_until = timezone('utc', now()) + interval '5 minutes';

UPDATE public.organization_memberships
SET status = 'suspended'
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '11111111-1111-1111-1111-111111111111';

SET ROLE service_role;
SELECT count(*) AS suspended_context_count
FROM public.resolve_ai_data_entry_execution_v1(
  'aaaaaaaa-0000-4000-8000-00000000b113',
  'pr12-review-worker'
) \gset
RESET ROLE;

UPDATE public.organization_memberships
SET status = 'active'
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '11111111-1111-1111-1111-111111111111';

SELECT CASE
  WHEN :'suspended_context_count'::integer = 0 THEN 1
  ELSE 1 / 0
END AS suspended_submitter_context_assertion;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
SELECT public.create_property_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'PR12-BIND-A', 'PR12 confirmed property',
  'Africa/Cairo', NULL, 'Cairo', NULL, NULL, NULL, NULL,
  'pr12-image-bind-a', NULL
) AS confirmed_property_id \gset
SELECT public.create_property_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'PR12-BIND-B', 'PR12 mismatch property',
  'Africa/Cairo', NULL, 'Cairo', NULL, NULL, NULL, NULL,
  'pr12-image-bind-b', NULL
) AS mismatch_property_id \gset
RESET ROLE;

SELECT set_config('voya.test.pr12_confirmed_property_id', :'confirmed_property_id', false);
SELECT set_config('voya.test.pr12_mismatch_property_id', :'mismatch_property_id', false);

INSERT INTO public.ai_data_entry_drafts (
  id, organization_id, created_by_membership_id, source_text, source_kind,
  idempotency_key, status, confirmation_payload, application_result,
  confirmed_by_membership_id, confirmed_at, confirmation_execution_token,
  confirmation_execution_claimed_at, confirmation_execution_heartbeat_at
)
SELECT
  'aaaaaaaa-0000-4000-8000-00000000b121'::uuid,
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  membership.id, '', 'image', 'pr12-image-bind-draft', 'confirmed',
  jsonb_build_object(
    'clients', '[]'::jsonb,
    'properties', jsonb_build_array(jsonb_build_object(
      'code', 'PR12-BIND-A', 'name', 'PR12 confirmed property', 'timezone', 'Africa/Cairo',
      'address', NULL, 'city', 'Cairo', 'unitLabel', NULL, 'bedrooms', NULL,
      'maxGuests', NULL, 'operationalNotes', NULL,
      'imageInputIds', jsonb_build_array('aaaaaaaa-0000-4000-8000-00000000b122'),
      'confidence', 'high', 'missingRequired', '[]'::jsonb
    )),
    'unresolved', '[]'::jsonb, 'warnings', '[]'::jsonb
  ),
  jsonb_build_object(
    'clients', '[]'::jsonb,
    'properties', jsonb_build_array(jsonb_build_object('index', 0, 'recordId', current_setting('voya.test.pr12_confirmed_property_id'))),
    'images', '[]'::jsonb
  ),
  membership.id, timezone('utc', now()),
  'aaaaaaaa-0000-4000-8000-00000000b123'::uuid,
  timezone('utc', now()), timezone('utc', now())
FROM public.organization_memberships AS membership
WHERE membership.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND membership.user_id = '11111111-1111-1111-1111-111111111111'
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.ai_data_entry_inputs (
  id, organization_id, draft_id, created_by_membership_id, storage_path,
  mime_type, byte_size, idempotency_key, status
)
SELECT
  'aaaaaaaa-0000-4000-8000-00000000b122'::uuid,
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  'aaaaaaaa-0000-4000-8000-00000000b121'::uuid,
  membership.id,
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/aaaaaaaa-0000-4000-8000-00000000b121/aaaaaaaa-0000-4000-8000-00000000b122.png',
  'image/png', 8, 'pr12-image-bind-input', 'active'
FROM public.organization_memberships AS membership
WHERE membership.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND membership.user_id = '11111111-1111-1111-1111-111111111111'
ON CONFLICT (id) DO NOTHING;

SET ROLE service_role;
DO $$
BEGIN
  BEGIN
    PERFORM public.apply_ai_data_entry_property_image_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-4000-8000-00000000b121',
      'aaaaaaaa-0000-4000-8000-00000000b122',
      current_setting('voya.test.pr12_mismatch_property_id')::uuid,
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || current_setting('voya.test.pr12_mismatch_property_id') || '/aaaaaaaa-0000-4000-8000-00000000b122.png',
      'image/png', 8, NULL, NULL,
      'ai-data-entry:aaaaaaaa-0000-4000-8000-00000000b121:property:0:image:aaaaaaaa-0000-4000-8000-00000000b122',
      'aaaaaaaa-0000-4000-8000-00000000b123',
      NULL
    );
    RAISE EXCEPTION 'service image application must reject a property that was not the durable confirmed result';
  EXCEPTION WHEN serialization_failure THEN NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'PR12 AI data-entry review regression tests passed' AS result;
