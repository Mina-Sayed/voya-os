-- Simulate a database which applied the October 6 clients wrapper before the
-- missing cross-branch bridge was installed. Roll back all catalog changes.
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE v_definition text;
BEGIN
  SELECT pg_get_functiondef('public.list_clients_v1_before_release_integration(uuid)'::regprocedure)
  INTO v_definition;
  EXECUTE replace(v_definition,
    'FUNCTION public.list_clients_v1_before_release_integration(',
    'FUNCTION public.list_clients_v1_without_workspace_aal2(');
  DROP FUNCTION public.list_clients_v1_before_release_integration(uuid);
END;
$$;
\ir ../migrations/20261005230000_release_integration_rpc_bridge.sql
-- Reapplying the missing bridge must preserve the same implementation.
\ir ../migrations/20261005230000_release_integration_rpc_bridge.sql
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aal":"aal1"}', true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.list_clients_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'late clients bridge bypassed AAL2';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aal":"aal2"}', true);
SELECT count(*) FROM public.list_clients_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
DO $$
BEGIN
  BEGIN
    PERFORM public.list_clients_v1('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
    RAISE EXCEPTION 'late clients bridge bypassed tenant membership';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;
DO $$
BEGIN
  IF has_function_privilege('authenticated', 'public.list_clients_v1_before_release_integration(uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.list_clients_v1_before_release_integration(uuid)', 'EXECUTE')
    OR has_function_privilege('service_role', 'public.list_clients_v1_before_release_integration(uuid)', 'EXECUTE')
    OR has_function_privilege('voya_outbox_worker', 'public.list_clients_v1_before_release_integration(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'late clients bridge exposed its private implementation';
  END IF;
END;
$$;
ROLLBACK;
SELECT 'release integration late migration upgrade passed' AS result;
