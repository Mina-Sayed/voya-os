-- A failed property insert must be correctable without creating another owner.
\set ON_ERROR_STOP on
BEGIN;
SELECT gen_random_uuid()::text AS correction_conversation_id \gset
INSERT INTO public.whatsapp_conversations (id, organization_id, channel_id, external_conversation_key, conversation_type)
SELECT :'correction_conversation_id'::uuid, organization_id, channel_id,
  'correction-' || :'correction_conversation_id', 'owner_onboarding'
FROM public.whatsapp_conversations
WHERE external_conversation_key = 'phase1-owner-confirm-thread';
SELECT jsonb_build_object(
  'owner', jsonb_build_object('displayName', 'Correction owner'),
  'property', jsonb_build_object('code', code, 'name', ' Correction property ', 'timezone', 'Africa/Cairo',
    'rentDaily', false, 'rentWeekly', false, 'rentMonthly', false, 'amenities', '[]'::jsonb),
  'ownershipStartDate', '2026-10-01', 'ownershipEndDate', '2027-10-01'
)::text AS correction_payload
FROM public.properties
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
ORDER BY created_at, id LIMIT 1 \gset
SELECT set_config('voya.test.correction_conversation_id', :'correction_conversation_id', true);
SELECT set_config('voya.test.correction_payload', :'correction_payload', true);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aal":"aal2"}', true);
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT * FROM public.claim_whatsapp_property_confirmation_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'correction_conversation_id',
  :'correction_payload'::jsonb, 1, 'correction-original-key', NULL
) \gset first_
SELECT public.create_property_owner_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Correction owner', NULL, NULL, NULL,
  NULL, NULL, 'whatsapp:' || :'correction_conversation_id' || ':correction-original-key:owner', NULL
)::text AS correction_owner_id \gset
DO $$
BEGIN
  BEGIN
    PERFORM public.create_property_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.correction_payload')::jsonb #>> '{property,code}',
      'Correction property', 'Africa/Cairo', NULL, NULL, NULL, NULL, NULL, NULL,
      'whatsapp:' || current_setting('voya.test.correction_conversation_id') || ':correction-original-key:property', NULL
    );
    RAISE EXCEPTION 'fixture must fail on the existing property code';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END;
$$;
SELECT public.finalize_whatsapp_property_confirmation_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'correction_conversation_id', :'first_confirmation_token',
  :'correction_owner_id', NULL, 'partially_applied',
  jsonb_build_object('propertyOwnerId', :'correction_owner_id', 'propertyId', NULL), NULL
);
RESET ROLE;
SELECT ai_state_version::text AS correction_version FROM public.whatsapp_conversations
WHERE id = :'correction_conversation_id'::uuid \gset
SELECT set_config('voya.test.correction_version', :'correction_version', true);
-- Denials must leave the partial snapshot untouched.
UPDATE public.organization_memberships SET status = 'active'
WHERE user_id = '33333333-3333-3333-3333-333333333333'
  AND organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aal":"aal1"}', true);
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.claim_whatsapp_property_confirmation_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.correction_conversation_id')::uuid,
      '{}'::jsonb, current_setting('voya.test.correction_version')::integer, 'aal1', NULL);
    RAISE EXCEPTION 'AAL1 correction unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aal":"aal2"}', true);
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.claim_whatsapp_property_confirmation_v1(
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', current_setting('voya.test.correction_conversation_id')::uuid,
      '{}'::jsonb, current_setting('voya.test.correction_version')::integer, 'cross-tenant', NULL);
    RAISE EXCEPTION 'cross-tenant correction unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.claim_whatsapp_property_confirmation_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.correction_conversation_id')::uuid,
      '{}'::jsonb, 1, 'stale-version', NULL);
    RAISE EXCEPTION 'stale correction unexpectedly succeeded';
  EXCEPTION WHEN serialization_failure THEN NULL;
  END;
END;
$$;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', true);
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.claim_whatsapp_property_confirmation_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.correction_conversation_id')::uuid,
      '{}'::jsonb, current_setting('voya.test.correction_version')::integer, 'viewer', NULL);
    RAISE EXCEPTION 'viewer correction unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT * FROM public.claim_whatsapp_property_confirmation_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'correction_conversation_id',
  jsonb_set(jsonb_set(:'correction_payload'::jsonb, '{property,code}', '"WA-CORRECTED"'),
    '{owner,displayName}', '"Must not overwrite created owner"'),
  :'correction_version'::integer, 'correction-reload-key', NULL
) \gset corrected_
SELECT set_config('voya.test.corrected_payload', :'corrected_confirmation_payload', true);
SELECT set_config('voya.test.corrected_result', :'corrected_confirmation_result', true);
SELECT set_config('voya.test.correction_owner_id', :'correction_owner_id', true);
DO $$
DECLARE v_payload jsonb := current_setting('voya.test.corrected_payload')::jsonb;
BEGIN
  IF v_payload #>> '{property,code}' <> 'WA-CORRECTED' THEN
    RAISE EXCEPTION 'corrected property code was discarded during partial recovery';
  END IF;
  IF v_payload -> 'owner' IS DISTINCT FROM current_setting('voya.test.correction_payload')::jsonb -> 'owner'
    OR current_setting('voya.test.corrected_result')::jsonb ->> 'propertyOwnerId'
      IS DISTINCT FROM current_setting('voya.test.correction_owner_id') THEN
    RAISE EXCEPTION 'recovery changed the already-created owner';
  END IF;
END;
$$;
-- An older concurrent Action must not insert superseded facts under the same key.
DO $$
BEGIN
  BEGIN
    PERFORM public.create_property_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.correction_payload')::jsonb #>> '{property,code}',
      'Correction property', 'Africa/Cairo', NULL, NULL, NULL, NULL, NULL, NULL,
      current_setting('voya.test.corrected_result')::jsonb #>> '{commandKeys,property}', NULL);
    RAISE EXCEPTION 'superseded property payload unexpectedly succeeded';
  EXCEPTION WHEN serialization_failure THEN NULL;
  END;
END;
$$;
SELECT public.create_property_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'corrected_confirmation_payload'::jsonb #>> '{property,code}', 'Correction property', 'Africa/Cairo',
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  false, false, false, NULL, NULL, NULL, NULL, ARRAY[]::text[], NULL, NULL,
  :'corrected_confirmation_result'::jsonb #>> '{commandKeys,property}', NULL
)::text AS correction_property_id \gset
-- Simulate a committed property insert whose response was lost: no propertyId in progress.
SELECT public.finalize_whatsapp_property_confirmation_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'correction_conversation_id', :'corrected_confirmation_token',
  :'correction_owner_id', NULL, 'partially_applied', :'corrected_confirmation_result'::jsonb, NULL
);
RESET ROLE;
SELECT ai_state_version::text AS correction_version FROM public.whatsapp_conversations
WHERE id = :'correction_conversation_id'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT * FROM public.claim_whatsapp_property_confirmation_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'correction_conversation_id',
  jsonb_set(:'corrected_confirmation_payload'::jsonb, '{property,code}', '"MUST-NOT-CHANGE"'),
  :'correction_version'::integer, 'after-lost-response', NULL
) \gset durable_
SELECT set_config('voya.test.durable_payload', :'durable_confirmation_payload', true);
SELECT set_config('voya.test.durable_result', :'durable_confirmation_result', true);
SELECT set_config('voya.test.correction_property_id', :'correction_property_id', true);
DO $$
BEGIN
  IF current_setting('voya.test.durable_payload')::jsonb #>> '{property,code}' <> 'WA-CORRECTED'
    OR current_setting('voya.test.durable_result')::jsonb ->> 'propertyId'
      IS DISTINCT FROM current_setting('voya.test.correction_property_id') THEN
    RAISE EXCEPTION 'recovery must discover and preserve the committed property';
  END IF;
END;
$$;
RESET ROLE;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.property_owners WHERE idempotency_key =
      'whatsapp:' || current_setting('voya.test.correction_conversation_id') || ':correction-original-key:owner') <> 1
    OR (SELECT count(*) FROM public.audit_events WHERE resource_id = current_setting('voya.test.correction_conversation_id')::uuid
      AND action = 'whatsapp.property_confirmation.resumed') <> 2 THEN
    RAISE EXCEPTION 'correction lost command identity or audit evidence';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc AS routine JOIN pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public' AND routine.proname = 'create_property_v1_before_whatsapp_correction'
      AND (has_function_privilege('authenticated', routine.oid, 'EXECUTE')
        OR has_function_privilege('anon', routine.oid, 'EXECUTE')
        OR has_function_privilege('service_role', routine.oid, 'EXECUTE'))
  ) THEN RAISE EXCEPTION 'private property creation implementations became callable'; END IF;
  IF has_function_privilege('anon', 'public.claim_whatsapp_property_confirmation_v1(uuid,uuid,jsonb,integer,text,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.claim_whatsapp_property_confirmation_v1(uuid,uuid,jsonb,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('service_role', 'public.claim_whatsapp_property_confirmation_v1_without_workspace_aal2(uuid,uuid,jsonb,integer,text,uuid)', 'EXECUTE')
 THEN
    RAISE EXCEPTION 'correction broadened confirmation grants';
  END IF;
END;
$$;
ROLLBACK;
SELECT 'WhatsApp partial property correction proofs passed' AS result;
