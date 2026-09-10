-- Workspace property-bearing reads and writes require a verified MFA session.
-- This suite is intentionally focused on the command/read entry points that
-- were not covered by the initial property wrapper migration.

DO $$
DECLARE
  required_function text;
  function_oid oid;
BEGIN
  FOREACH required_function IN ARRAY ARRAY[
    'public.create_availability_block(uuid,uuid,date,date,text,text,text,uuid)',
    'public.list_availability_blocks(uuid)',
    'public.list_commercial_booking_work_queue(uuid)',
    'public.list_whatsapp_conversations_ai_v1(uuid)',
    'public.claim_whatsapp_property_confirmation_v1(uuid,uuid,jsonb,integer,text,uuid)',
    'public.finalize_whatsapp_property_confirmation_v1(uuid,uuid,uuid,uuid,uuid,text,jsonb,uuid)'
  ] LOOP
    function_oid := to_regprocedure(required_function);
    IF function_oid IS NULL THEN
      RAISE EXCEPTION 'required AAL2 closure function is missing: %', required_function;
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM pg_proc AS routine
      WHERE routine.oid = function_oid
        AND routine.prosecdef
        AND 'search_path=pg_catalog' = ANY (routine.proconfig)
    ) THEN
      RAISE EXCEPTION 'AAL2 wrapper must be SECURITY DEFINER with a pinned search_path: %', required_function;
    END IF;
  END LOOP;

  IF has_function_privilege('anon', 'public.create_availability_block(uuid,uuid,date,date,text,text,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.list_availability_blocks(uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.list_commercial_booking_work_queue(uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.list_whatsapp_conversations_ai_v1(uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.claim_whatsapp_property_confirmation_v1(uuid,uuid,jsonb,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.finalize_whatsapp_property_confirmation_v1(uuid,uuid,uuid,uuid,uuid,text,jsonb,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'property-bearing AAL2 entry points must not be executable by anon';
  END IF;

  IF has_function_privilege('voya_outbox_worker', 'public.create_availability_block(uuid,uuid,date,date,text,text,text,uuid)', 'EXECUTE')
    OR has_function_privilege('voya_outbox_worker', 'public.list_availability_blocks(uuid)', 'EXECUTE')
    OR has_function_privilege('voya_outbox_worker', 'public.list_commercial_booking_work_queue(uuid)', 'EXECUTE')
    OR has_function_privilege('voya_outbox_worker', 'public.list_whatsapp_conversations_ai_v1(uuid)', 'EXECUTE')
    OR has_function_privilege('voya_outbox_worker', 'public.claim_whatsapp_property_confirmation_v1(uuid,uuid,jsonb,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('voya_outbox_worker', 'public.finalize_whatsapp_property_confirmation_v1(uuid,uuid,uuid,uuid,uuid,text,jsonb,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'property-bearing AAL2 entry points must remain outside the worker boundary';
  END IF;

  IF has_function_privilege('authenticated', 'public.create_availability_block_without_workspace_aal2(uuid,uuid,date,date,text,text,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.list_availability_blocks_without_workspace_aal2(uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.list_commercial_booking_work_queue_without_workspace_aal2(uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.list_whatsapp_conversations_ai_v1_without_workspace_aal2(uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.claim_whatsapp_property_confirmation_v1_without_workspace_aal2(uuid,uuid,jsonb,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.finalize_whatsapp_property_confirmation_v1_without_workspace_aal2(uuid,uuid,uuid,uuid,uuid,text,jsonb,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'internal pre-AAL2 implementations must remain revoked';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal1', false);

DO $$
BEGIN
  BEGIN
    PERFORM public.create_availability_block(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      DATE '2049-01-01', DATE '2049-01-02', 'maintenance', NULL,
      'aal1-availability-denied', NULL
    );
    RAISE EXCEPTION 'AAL1 availability writes must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    PERFORM public.list_availability_blocks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'AAL1 availability reads must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    PERFORM public.list_commercial_booking_work_queue('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'AAL1 commercial booking property reads must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    PERFORM public.list_whatsapp_conversations_ai_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'AAL1 WhatsApp property-bearing reads must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    PERFORM public.claim_whatsapp_property_confirmation_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      '{}'::jsonb, 1, 'aal1-confirmation-denied', NULL
    );
    RAISE EXCEPTION 'AAL1 property confirmation claims must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    PERFORM public.finalize_whatsapp_property_confirmation_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000002', NULL, NULL,
      'needs_review', '{}'::jsonb, NULL
    );
    RAISE EXCEPTION 'AAL1 property confirmation finalization must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

SELECT set_config('request.jwt.claim.aal', 'aal2', false);

DO $$
BEGIN
  -- These reads prove the wrappers delegate successfully after AAL2. They do
  -- not require fixture-specific rows and therefore remain stable as the
  -- broader integration suite evolves.
  PERFORM public.list_availability_blocks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  PERFORM public.list_commercial_booking_work_queue('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  PERFORM public.list_whatsapp_conversations_ai_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
END;
$$;

RESET ROLE;

SELECT 'property AAL2 closure tests passed' AS result;
