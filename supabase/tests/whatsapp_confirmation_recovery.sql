-- Recovery proof for old partially-applied WhatsApp property confirmations.
-- Run after whatsapp_ai_agent_phase1.sql seeds the owner-confirm conversation.

DO $$
BEGIN
  IF has_function_privilege('anon', 'public.claim_whatsapp_property_confirmation_v1(uuid,uuid,jsonb,integer,text,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.claim_whatsapp_property_confirmation_v1(uuid,uuid,jsonb,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.claim_whatsapp_property_confirmation_v1_without_workspace_aal2(uuid,uuid,jsonb,integer,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'confirmation resume must retain the authenticated AAL2 wrapper and private implementation';
  END IF;
END;
$$;

SELECT conversation.id::text AS recovery_conversation_id,
  conversation.property_owner_id::text AS recovery_owner_id,
  conversation.property_id::text AS recovery_property_id,
  conversation.confirmation_payload::text AS recovery_original_payload
FROM public.whatsapp_conversations AS conversation
WHERE conversation.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND conversation.external_conversation_key = 'phase1-owner-confirm-thread'
\gset

SELECT period.id::text AS recovery_ownership_period_id
FROM public.property_ownership_periods AS period
WHERE period.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND period.property_id = :'recovery_property_id'::uuid
  AND period.property_owner_id = :'recovery_owner_id'::uuid
  AND period.start_date = DATE '2026-08-27'
  AND period.end_date = DATE '2099-12-31'
\gset

UPDATE public.property_ownership_periods
SET idempotency_key = 'whatsapp:' || :'recovery_conversation_id' || ':legacy-confirmation-key:ownership'
WHERE id = :'recovery_ownership_period_id'::uuid;

UPDATE public.whatsapp_conversations
SET confirmation_status = 'partially_applied',
    confirmation_key = 'legacy-confirmation-key',
    confirmation_token = 'aaaaaaaa-0000-0000-0000-000000009101',
    confirmation_claimed_at = timezone('utc', now()),
    confirmation_result = jsonb_build_object(
      'errorCode', 'whatsapp_property_image_upload_failed',
      'propertyOwnerId', :'recovery_owner_id'::uuid,
      'propertyId', :'recovery_property_id'::uuid
    ),
    ai_state_version = ai_state_version + 1
WHERE id = :'recovery_conversation_id'::uuid;

SELECT ai_state_version::text AS recovery_expected_version
FROM public.whatsapp_conversations
WHERE id = :'recovery_conversation_id'::uuid
\gset

SELECT set_config('voya.test.recovery_conversation_id', :'recovery_conversation_id', false);
SELECT set_config('voya.test.recovery_expected_version', :'recovery_expected_version', false);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal1', false);
DO $$
BEGIN
  BEGIN
    PERFORM 1
    FROM public.claim_whatsapp_property_confirmation_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.recovery_conversation_id')::uuid,
      '{}'::jsonb,
      current_setting('voya.test.recovery_expected_version')::integer,
      'aal1-recovery-attempt',
      'aaaaaaaa-0000-0000-0000-000000009104'
    );
    RAISE EXCEPTION 'AAL1 must not claim a WhatsApp property confirmation';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
SELECT * FROM public.claim_whatsapp_property_confirmation_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'recovery_conversation_id'::uuid,
  '{}'::jsonb,
  :'recovery_expected_version'::integer,
  'reload-generated-key',
  'aaaaaaaa-0000-0000-0000-000000009102'
) \gset recovered_
SELECT public.assign_property_owner_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'recovery_property_id'::uuid,
  :'recovery_owner_id'::uuid,
  DATE '2026-08-27',
  DATE '2099-12-31',
  true,
  (:'recovered_confirmation_result'::jsonb #>> '{commandKeys,ownership}'),
  'aaaaaaaa-0000-0000-0000-000000009103'
)::text AS recovered_assignment_id \gset
RESET ROLE;

SELECT set_config('voya.test.recovery_outcome', :'recovered_outcome', false);
SELECT set_config('voya.test.recovery_payload', :'recovered_confirmation_payload', false);
SELECT set_config('voya.test.recovery_result', :'recovered_confirmation_result', false);
SELECT set_config('voya.test.recovery_assignment_id', :'recovered_assignment_id', false);
SELECT set_config('voya.test.recovery_original_payload', :'recovery_original_payload', false);
SELECT set_config('voya.test.recovery_ownership_period_id', :'recovery_ownership_period_id', false);
SELECT set_config('voya.test.recovery_owner_id', :'recovery_owner_id', false);
SELECT set_config('voya.test.recovery_property_id', :'recovery_property_id', false);
SELECT set_config('voya.test.recovery_expected_attempt_key', 'whatsapp:' || :'recovery_conversation_id' || ':legacy-confirmation-key', false);

DO $$
DECLARE
  v_result jsonb := current_setting('voya.test.recovery_result')::jsonb;
  v_payload jsonb := current_setting('voya.test.recovery_payload')::jsonb;
BEGIN
  IF current_setting('voya.test.recovery_outcome') <> 'claimed' THEN
    RAISE EXCEPTION 'partially-applied confirmation must return a resumable claim';
  END IF;
  IF v_result ->> 'attemptKey' <> current_setting('voya.test.recovery_expected_attempt_key') THEN
    RAISE EXCEPTION 'resume must preserve the original sub-command attempt key: %', v_result;
  END IF;
  IF v_result ->> 'ownershipPeriodId' <> current_setting('voya.test.recovery_ownership_period_id') THEN
    RAISE EXCEPTION 'legacy partial result must recover its existing ownership period: %', v_result;
  END IF;
  IF (v_result #>> '{commandKeys,ownership}') <> (v_result ->> 'attemptKey') || ':ownership' THEN
    RAISE EXCEPTION 'ownership retry must use the original idempotency key: %', v_result;
  END IF;
  IF v_payload <> current_setting('voya.test.recovery_original_payload')::jsonb THEN
    RAISE EXCEPTION 'resume must return the original accepted payload';
  END IF;
  IF current_setting('voya.test.recovery_assignment_id') <> v_result ->> 'ownershipPeriodId' THEN
    RAISE EXCEPTION 'assign retry must return the existing period instead of an exclusion error';
  END IF;
END;
$$;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.property_ownership_periods AS period
      WHERE period.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND period.property_id = current_setting('voya.test.recovery_property_id')::uuid
        AND period.property_owner_id = current_setting('voya.test.recovery_owner_id')::uuid
        AND period.start_date = DATE '2026-08-27'
        AND period.end_date = DATE '2099-12-31') <> 1 THEN
    RAISE EXCEPTION 'recovery must leave exactly one ownership period';
  END IF;
END;
$$;
