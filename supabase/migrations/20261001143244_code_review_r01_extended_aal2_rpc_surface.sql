-- Close the remaining authenticated human workspace RPCs omitted from the first
-- R01 inventory. Keep invitation acceptance as the only intentional AAL1
-- pre-workspace command; onboarding pages/actions already require verified MFA.
DO $migration$
DECLARE
  v_signature text;
  v_function_oid oid;
  v_schema_name text;
  v_function_name text;
  v_inner_name text;
  v_owner_name text;
  v_owner_oid oid;
  v_input_types oidvector;
  v_argument_count integer;
  v_return_type oid;
  v_returns_set boolean;
  v_original_acl aclitem[];
  v_identity_types text;
  v_call_arguments text;
  v_definition text;
  v_header text;
  v_header_end integer;
  v_grantee record;
  v_protected_signatures constant text[] := ARRAY[
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
  ];
BEGIN
  IF to_regprocedure('public.require_workspace_aal2_v1()') IS NULL THEN
    RAISE EXCEPTION 'workspace AAL2 guard is required before extending R01';
  END IF;

  FOREACH v_signature IN ARRAY v_protected_signatures LOOP
    v_function_oid := to_regprocedure(v_signature);
    IF v_function_oid IS NULL THEN
      RAISE EXCEPTION 'R01 extended protected RPC signature is missing: %', v_signature;
    END IF;

    SELECT namespace.nspname, routine.proname, routine.proowner,
           owner_role.rolname, routine.proargtypes, routine.pronargs,
           routine.prorettype, routine.proretset, routine.proacl
      INTO v_schema_name, v_function_name, v_owner_oid, v_owner_name,
           v_input_types, v_argument_count, v_return_type, v_returns_set,
           v_original_acl
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    JOIN pg_catalog.pg_roles AS owner_role ON owner_role.oid = routine.proowner
    WHERE routine.oid = v_function_oid;

    IF NOT (SELECT routine.prosecdef FROM pg_catalog.pg_proc AS routine WHERE routine.oid = v_function_oid)
      OR NOT EXISTS (
        SELECT 1
        FROM unnest(coalesce(
          (SELECT routine.proconfig FROM pg_catalog.pg_proc AS routine WHERE routine.oid = v_function_oid),
          ARRAY[]::text[]
        )) AS setting
        WHERE setting LIKE 'search_path=%'
      ) THEN
      RAISE EXCEPTION 'R01 extended RPC must remain SECURITY DEFINER with a pinned search_path: %', v_signature;
    END IF;
    IF NOT has_function_privilege('authenticated', v_function_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'R01 extended authenticated grant is missing: %', v_signature;
    END IF;
    IF has_function_privilege('anon', v_function_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'R01 extended RPC unexpectedly grants anon EXECUTE: %', v_signature;
    END IF;

    v_inner_name := v_function_name || '_without_workspace_aal2_r01';
    IF length(v_inner_name) > 63 THEN
      RAISE EXCEPTION 'R01 extended private implementation name exceeds PostgreSQL limit: %', v_inner_name;
    END IF;
    SELECT string_agg(pg_catalog.format_type(argument_type, NULL), ', ' ORDER BY ordinal_position)
      INTO v_identity_types
    FROM unnest(v_input_types) WITH ORDINALITY AS input_argument(argument_type, ordinal_position);
    IF to_regprocedure(format('%I.%I(%s)', v_schema_name, v_inner_name, v_identity_types)) IS NOT NULL THEN
      RAISE EXCEPTION 'R01 extended private implementation name already exists: %.%', v_schema_name, v_inner_name;
    END IF;

    v_definition := pg_catalog.pg_get_functiondef(v_function_oid);
    v_header_end := strpos(v_definition, 'AS $function$');
    IF v_header_end = 0 THEN
      RAISE EXCEPTION 'R01 extended RPC has an unsupported function definition format: %', v_signature;
    END IF;
    v_header := substring(v_definition FROM 1 FOR v_header_end + length('AS $function$') - 1);
    SELECT string_agg(format('$%s', argument_position), ', ' ORDER BY argument_position)
      INTO v_call_arguments
    FROM generate_series(1, v_argument_count) AS input_argument(argument_position);
    v_call_arguments := coalesce(v_call_arguments, '');

    EXECUTE format(
      'ALTER FUNCTION %I.%I(%s) RENAME TO %I',
      v_schema_name, v_function_name, v_identity_types, v_inner_name
    );
    EXECUTE format(
      'REVOKE ALL ON FUNCTION %I.%I(%s) FROM PUBLIC, anon, authenticated',
      v_schema_name, v_inner_name, v_identity_types
    );

    v_definition := v_header || E'\nBEGIN\n  IF auth.jwt() ->> ''role'' = ''authenticated'' THEN\n    PERFORM public.require_workspace_aal2_v1();\n  END IF;\n';
    IF v_return_type = 'void'::regtype THEN
      v_definition := v_definition || format(
        E'  PERFORM %I.%I(%s);\n  RETURN;\nEND;\n$function$;',
        v_schema_name, v_inner_name, v_call_arguments
      );
    ELSIF v_returns_set THEN
      v_definition := v_definition || format(
        E'  RETURN QUERY SELECT * FROM %I.%I(%s);\nEND;\n$function$;',
        v_schema_name, v_inner_name, v_call_arguments
      );
    ELSE
      v_definition := v_definition || format(
        E'  RETURN %I.%I(%s);\nEND;\n$function$;',
        v_schema_name, v_inner_name, v_call_arguments
      );
    END IF;
    EXECUTE v_definition;
    EXECUTE format(
      'ALTER FUNCTION %I.%I(%s) OWNER TO %I',
      v_schema_name, v_function_name, v_identity_types, v_owner_name
    );
    EXECUTE format(
      'REVOKE ALL ON FUNCTION %I.%I(%s) FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker',
      v_schema_name, v_function_name, v_identity_types
    );

    FOR v_grantee IN
      SELECT role.rolname, bool_or(privilege.is_grantable) AS grantable
      FROM aclexplode(coalesce(v_original_acl, acldefault('f', v_owner_oid))) AS privilege
      JOIN pg_catalog.pg_roles AS role ON role.oid = privilege.grantee
      WHERE privilege.privilege_type = 'EXECUTE'
        AND privilege.grantee <> v_owner_oid
      GROUP BY role.rolname
      ORDER BY role.rolname
    LOOP
      EXECUTE format(
        'GRANT EXECUTE ON FUNCTION %I.%I(%s) TO %I%s',
        v_schema_name, v_function_name, v_identity_types, v_grantee.rolname,
        CASE WHEN v_grantee.grantable THEN ' WITH GRANT OPTION' ELSE '' END
      );
    END LOOP;
  END LOOP;
END;
$migration$;
