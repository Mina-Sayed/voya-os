-- Both review branches introduced the same private clients-read signature.
-- Relocate the earlier implementation before the October 6 forward migration
-- installs its wrapper. This also preserves an already installed October 6
-- wrapper when this missing migration is applied during an upgrade.
DO $migration$
DECLARE
  v_private oid := to_regprocedure('public.list_clients_v1_without_workspace_aal2(uuid)');
  v_definition text;
BEGIN
  IF to_regprocedure('public.list_clients_v1_before_release_integration(uuid)') IS NOT NULL THEN
    RETURN;
  END IF;
  IF v_private IS NULL THEN
    RAISE EXCEPTION 'clients read implementation is missing before release integration';
  END IF;
  SELECT pg_get_functiondef('public.list_clients_v1(uuid)'::regprocedure)
  INTO v_definition;
  IF strpos(v_definition, 'public.list_clients_v1_without_workspace_aal2(') = 0
    OR strpos(v_definition, 'PERFORM public.require_workspace_aal2_v1()') = 0 THEN
    RAISE EXCEPTION 'clients read wrapper changed unexpectedly before release integration';
  END IF;
  ALTER FUNCTION public.list_clients_v1_without_workspace_aal2(uuid)
    RENAME TO list_clients_v1_before_release_integration;
  REVOKE ALL ON FUNCTION public.list_clients_v1_before_release_integration(uuid)
    FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker;
  EXECUTE replace(v_definition,
    'public.list_clients_v1_without_workspace_aal2(',
    'public.list_clients_v1_before_release_integration(');
END;
$migration$;
