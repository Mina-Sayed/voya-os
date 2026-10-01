-- R01 extension: human workspace RPCs omitted from the first command-family inventory.
\set ON_ERROR_STOP on

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claim.email', 'owner@example.test', true);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal1"}',
  true
);

DO $$
DECLARE
  v_function record;
  v_arguments text;
  v_invocation text;
  v_message text;
  v_count integer := 0;
BEGIN
  FOR v_function IN
    SELECT p.oid, p.proname, p.proargtypes
    FROM unnest(ARRAY[
      to_regprocedure('public.create_whatsapp_channel(uuid,text,text,text,uuid)'),
      to_regprocedure('public.list_whatsapp_channels(uuid)'),
      to_regprocedure('public.create_whatsapp_conversation(uuid,uuid,text,uuid,uuid,uuid,uuid)'),
      to_regprocedure('public.create_whatsapp_message(uuid,uuid,text,text,uuid)'),
      to_regprocedure('public.assign_whatsapp_conversation(uuid,uuid,uuid,uuid)'),
      to_regprocedure('public.add_whatsapp_internal_note(uuid,uuid,text,text,uuid)'),
      to_regprocedure('public.set_whatsapp_ai_enabled_v1(uuid,uuid,boolean,uuid)'),
      to_regprocedure('public.create_ai_run_request(uuid,text,text,text,uuid)'),
      to_regprocedure('public.list_ai_runs(uuid,integer)'),
      to_regprocedure('public.list_ai_tool_calls(uuid,uuid)'),
      to_regprocedure('public.get_ai_run_result_v1(uuid,uuid)'),
      to_regprocedure('public.list_audit_activity(uuid,integer)'),
      to_regprocedure('public.list_audit_activity_filtered(uuid,integer,timestamp with time zone,timestamp with time zone,uuid,text,text)'),
      to_regprocedure('public.list_my_notifications(uuid,integer)'),
      to_regprocedure('public.mark_notification_read(uuid,uuid)'),
      to_regprocedure('public.get_system_health_v1(uuid)'),
      to_regprocedure('public.create_organization(text,text,text,uuid)'),
      to_regprocedure('public.bootstrap_personal_workspace(uuid)')
    ]) AS target(oid)
    JOIN pg_catalog.pg_proc AS p ON p.oid = target.oid
    ORDER BY p.proname, p.oid
  LOOP
    SELECT string_agg(
      format('NULL::%s', pg_catalog.format_type(argument_type, NULL)),
      ', ' ORDER BY ordinal_position
    )
    INTO v_arguments
    FROM unnest(v_function.proargtypes) WITH ORDINALITY AS input_argument(argument_type, ordinal_position);
    v_invocation := format('SELECT * FROM public.%I(%s)', v_function.proname, coalesce(v_arguments, ''));

    BEGIN
      EXECUTE v_invocation;
      RAISE EXCEPTION 'R01 regression: AAL1 RPC call unexpectedly succeeded: %', v_function.oid::regprocedure;
    EXCEPTION WHEN SQLSTATE '42501' THEN
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
      IF v_message NOT LIKE '%MFA AAL2 is required%' THEN
        RAISE EXCEPTION 'R01 regression: AAL1 reached domain authorization instead of MFA at %: %',
          v_function.oid::regprocedure, v_message;
      END IF;
    END;
    v_count := v_count + 1;
  END LOOP;

  IF v_count <> 18 THEN
    RAISE EXCEPTION 'R01 extended inventory expected 18 signatures, checked %', v_count;
  END IF;
END;
$$;

DO $$
DECLARE
  v_function record;
  v_arguments text;
  v_invocation text;
  v_message text;
  v_count integer := 0;
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal2"}',
    true
  );
  PERFORM set_config('request.jwt.claim.aal', 'aal2', true);

  FOR v_function IN
    SELECT p.oid, p.proname, p.proargtypes
    FROM unnest(ARRAY[
      to_regprocedure('public.create_whatsapp_channel(uuid,text,text,text,uuid)'),
      to_regprocedure('public.list_whatsapp_channels(uuid)'),
      to_regprocedure('public.create_whatsapp_conversation(uuid,uuid,text,uuid,uuid,uuid,uuid)'),
      to_regprocedure('public.create_whatsapp_message(uuid,uuid,text,text,uuid)'),
      to_regprocedure('public.assign_whatsapp_conversation(uuid,uuid,uuid,uuid)'),
      to_regprocedure('public.add_whatsapp_internal_note(uuid,uuid,text,text,uuid)'),
      to_regprocedure('public.set_whatsapp_ai_enabled_v1(uuid,uuid,boolean,uuid)'),
      to_regprocedure('public.create_ai_run_request(uuid,text,text,text,uuid)'),
      to_regprocedure('public.list_ai_runs(uuid,integer)'),
      to_regprocedure('public.list_ai_tool_calls(uuid,uuid)'),
      to_regprocedure('public.get_ai_run_result_v1(uuid,uuid)'),
      to_regprocedure('public.list_audit_activity(uuid,integer)'),
      to_regprocedure('public.list_audit_activity_filtered(uuid,integer,timestamp with time zone,timestamp with time zone,uuid,text,text)'),
      to_regprocedure('public.list_my_notifications(uuid,integer)'),
      to_regprocedure('public.mark_notification_read(uuid,uuid)'),
      to_regprocedure('public.get_system_health_v1(uuid)'),
      to_regprocedure('public.create_organization(text,text,text,uuid)'),
      to_regprocedure('public.bootstrap_personal_workspace(uuid)')
    ]) AS target(oid)
    JOIN pg_catalog.pg_proc AS p ON p.oid = target.oid
    ORDER BY p.proname, p.oid
  LOOP
    SELECT string_agg(
      format('NULL::%s', pg_catalog.format_type(argument_type, NULL)),
      ', ' ORDER BY ordinal_position
    )
    INTO v_arguments
    FROM unnest(v_function.proargtypes) WITH ORDINALITY AS input_argument(argument_type, ordinal_position);
    v_invocation := format('SELECT * FROM public.%I(%s)', v_function.proname, coalesce(v_arguments, ''));

    BEGIN
      EXECUTE v_invocation;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
      IF v_message LIKE '%MFA AAL2 is required%' THEN
        RAISE EXCEPTION 'R01 regression: AAL2 was rejected by the wrapper at %', v_function.oid::regprocedure;
      END IF;
    END;
    v_count := v_count + 1;
  END LOOP;

  IF v_count <> 18 THEN
    RAISE EXCEPTION 'R01 extended AAL2 inventory expected 18 signatures, checked %', v_count;
  END IF;
END;
$$;

DO $$
DECLARE
  v_signature text;
  v_function_oid oid;
  v_inner_oid oid;
  v_function_name text;
  v_inner_name text;
  v_count integer := 0;
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'public.create_whatsapp_channel(uuid,text,text,text,uuid)',
    'public.list_whatsapp_channels(uuid)',
    'public.create_whatsapp_conversation(uuid,uuid,text,uuid,uuid,uuid,uuid)',
    'public.create_whatsapp_message(uuid,uuid,text,text,uuid)',
    'public.assign_whatsapp_conversation(uuid,uuid,uuid,uuid)',
    'public.add_whatsapp_internal_note(uuid,uuid,text,text,uuid)',
    'public.set_whatsapp_ai_enabled_v1(uuid,uuid,boolean,uuid)',
    'public.create_ai_run_request(uuid,text,text,text,uuid)',
    'public.list_ai_runs(uuid,integer)',
    'public.list_ai_tool_calls(uuid,uuid)',
    'public.get_ai_run_result_v1(uuid,uuid)',
    'public.list_audit_activity(uuid,integer)',
    'public.list_audit_activity_filtered(uuid,integer,timestamptz,timestamptz,uuid,text,text)',
    'public.list_my_notifications(uuid,integer)',
    'public.mark_notification_read(uuid,uuid)',
    'public.get_system_health_v1(uuid)',
    'public.create_organization(text,text,text,uuid)',
    'public.bootstrap_personal_workspace(uuid)'
  ] LOOP
    v_function_oid := to_regprocedure(v_signature);
    IF v_function_oid IS NULL THEN RAISE EXCEPTION 'R01 extended signature missing: %', v_signature; END IF;
    SELECT routine.proname INTO v_function_name FROM pg_catalog.pg_proc AS routine WHERE routine.oid = v_function_oid;
    v_inner_name := v_function_name || '_without_workspace_aal2_r01';
    SELECT private_function.oid INTO v_inner_oid
    FROM pg_catalog.pg_proc AS private_function
    JOIN pg_catalog.pg_namespace AS private_namespace ON private_namespace.oid = private_function.pronamespace
    WHERE private_namespace.nspname = 'public'
      AND private_function.proname = v_inner_name
      AND private_function.proargtypes = (SELECT routine.proargtypes FROM pg_catalog.pg_proc AS routine WHERE routine.oid = v_function_oid);
    IF v_inner_oid IS NULL
      OR NOT has_function_privilege('authenticated', v_function_oid, 'EXECUTE')
      OR has_function_privilege('anon', v_function_oid, 'EXECUTE')
      OR has_function_privilege('authenticated', v_inner_oid, 'EXECUTE')
      OR has_function_privilege('anon', v_inner_oid, 'EXECUTE')
      OR NOT (SELECT routine.prosecdef FROM pg_catalog.pg_proc AS routine WHERE routine.oid = v_function_oid)
      OR NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(
          (SELECT routine.proconfig FROM pg_catalog.pg_proc AS routine WHERE routine.oid = v_function_oid),
          ARRAY[]::text[]
        )) AS setting WHERE setting LIKE 'search_path=%'
      )
      OR position('PERFORM public.require_workspace_aal2_v1()' IN pg_catalog.pg_get_functiondef(v_function_oid)) = 0 THEN
      RAISE EXCEPTION 'R01 extended wrapper or private ACL is invalid: %', v_signature;
    END IF;
    v_count := v_count + 1;
  END LOOP;
  IF v_count <> 18 THEN RAISE EXCEPTION 'R01 extended catalog inventory expected 18, checked %', v_count; END IF;
END;
$$;

RESET ROLE;
ROLLBACK;

SELECT 'R01 extended workspace AAL2 closure tests passed' AS result;
