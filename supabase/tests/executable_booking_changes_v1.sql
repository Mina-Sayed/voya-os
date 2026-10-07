-- Executable booking change projection contract.
\set ON_ERROR_STOP on

DO $$
DECLARE
  wrapper_definition text;
  implementation_definition text;
  is_security_definer boolean;
  function_config text[];
BEGIN
  IF to_regprocedure('public.list_executable_booking_changes_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'executable booking change projection is missing';
  END IF;

  IF has_function_privilege('anon', 'public.list_executable_booking_changes_v1(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute executable booking change projection';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.list_executable_booking_changes_v1(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated role must be able to call the guarded projection';
  END IF;

  SELECT procedure.prosecdef, procedure.proconfig
  INTO is_security_definer, function_config
  FROM pg_catalog.pg_proc AS procedure
  WHERE procedure.oid = 'public.list_executable_booking_changes_v1(uuid)'::regprocedure;

  IF is_security_definer IS DISTINCT FROM true
    OR function_config IS NULL
    OR NOT ('search_path=pg_catalog' = ANY(function_config)) THEN
    RAISE EXCEPTION 'executable booking change projection must lock its SECURITY DEFINER search path';
  END IF;

  SELECT pg_get_functiondef('public.list_executable_booking_changes_v1(uuid)'::regprocedure)
  INTO wrapper_definition;
  SELECT pg_get_functiondef('public.list_executable_booking_changes_v1_without_workspace_aal2(uuid)'::regprocedure)
  INTO implementation_definition;

  implementation_definition := implementation_definition || pg_get_functiondef('public.list_executable_booking_changes_v1_without_review_aal2(uuid)'::regprocedure);

  IF wrapper_definition NOT LIKE '%PERFORM public.require_workspace_aal2_v1()%'
    OR implementation_definition NOT LIKE '%request.status = ''approved''%'
    OR implementation_definition NOT LIKE '%request.expires_at >%'
    OR implementation_definition NOT LIKE '%request.requester_membership_id <> v_actor%'
    OR implementation_definition NOT LIKE '%booking.status = ''pending_approval''%'
    OR implementation_definition NOT LIKE '%booking.status = ''confirmed''%'
    OR implementation_definition NOT LIKE '%confirmation_property.status = ''active''%'
    OR implementation_definition NOT LIKE '%amendment_property.status = ''active''%'
    OR implementation_definition NOT LIKE '%amendment_client.archived_at IS NULL%' THEN
    RAISE EXCEPTION 'executable booking change projection is missing required state boundaries';
  END IF;
END;
$$;

SELECT 'executable booking change projection tests passed' AS result;
