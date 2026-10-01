-- R01: put the database-owned workspace MFA gate in front of every current
-- authenticated booking/approval/stay, CRM, fleet/transport, task, and
-- organization-onboarding RPC. Preserve each public signature and effective
-- non-browser grants; worker/service-role calls keep their previous trust path.

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
  v_new_definition text;
  v_worker_grants integer := 0;
  v_wrapped integer := 0;
  v_existing_aal2 integer := 0;
  v_grantee record;
  v_protected_signatures constant text[] := ARRAY[
    'public.archive_client_v1(uuid,uuid,text,integer,text,uuid)',
    'public.archive_lead_v1(uuid,uuid,text,integer,text,uuid)',
    'public.assign_transport_request(uuid,uuid,uuid,uuid,uuid)',
    'public.cancel_booking_draft(uuid,uuid,text,text,uuid)',
    'public.complete_booking_commercial_snapshot(uuid,uuid,text,text,text,text,uuid)',
    'public.complete_lead_follow_up_v1(uuid,uuid,text,text,uuid)',
    'public.complete_organization_onboarding(uuid,text,text,text,uuid)',
    'public.confirm_booking(uuid,uuid,text,uuid)',
    'public.confirm_commercial_booking(uuid,uuid,text,uuid)',
    'public.convert_lead_to_client_v1(uuid,uuid,text,uuid)',
    'public.create_booking_draft(uuid,uuid,uuid,date,date,text,uuid)',
    'public.create_client(uuid,text,text,uuid)',
    'public.create_client_v1(uuid,text,text,text,text,text,text,text,uuid,text,uuid)',
    'public.create_commercial_booking_draft(uuid,uuid,uuid,date,date,text,text,text,uuid)',
    'public.create_crm_contact_method(uuid,text,text,text,uuid,uuid,text,uuid)',
    'public.create_fleet_driver_v1(uuid,text,text,text,uuid)',
    'public.create_fleet_vehicle_v1(uuid,text,text,text,integer,text,uuid)',
    'public.create_lead(uuid,text,text,text,date,date,uuid,text,uuid)',
    'public.create_lead_activity_v1(uuid,uuid,text,text,text,uuid)',
    'public.create_lead_follow_up_v1(uuid,uuid,timestamp with time zone,text,uuid,text,uuid)',
    'public.create_lead_v1(uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamp with time zone,text,uuid)',
    'public.create_operations_task(uuid,text,text,text,timestamp with time zone,uuid,uuid,text,uuid)',
    'public.create_transport_request(uuid,text,text,text,text,timestamp with time zone,integer,timestamp with time zone,uuid,text,text,uuid)',
    'public.decide_booking_approval(uuid,uuid,text,text,uuid)',
    'public.execute_booking_amendment(uuid,uuid,uuid,text,uuid)',
    'public.execute_booking_cancellation(uuid,uuid,text,uuid)',
    'public.list_approval_requests(uuid,integer)',
    'public.list_approval_requests_v2(uuid,integer)',
    'public.list_booking_drafts(uuid)',
    'public.list_booking_work_queue(uuid)',
    'public.list_clients(uuid)',
    'public.list_clients_v1(uuid)',
    'public.list_commercial_booking_work_queue(uuid)',
    'public.list_executable_booking_changes_v1(uuid)',
    'public.list_fleet_drivers(uuid)',
    'public.list_fleet_vehicles(uuid)',
    'public.list_lead_activities_v1(uuid,uuid)',
    'public.list_lead_follow_ups_v1(uuid,uuid)',
    'public.list_leads(uuid)',
    'public.list_leads_v1(uuid)',
    'public.list_operations_tasks(uuid,integer)',
    'public.list_transport_requests(uuid,integer)',
    'public.record_booking_stay_event(uuid,uuid,text,text,text,uuid)',
    'public.record_commercial_booking_stay_event(uuid,uuid,text,text,text,uuid)',
    'public.record_crm_consent(uuid,uuid,text,text,text,text,uuid)',
    'public.request_booking_amendment(uuid,uuid,uuid,uuid,date,date,text,text,text,text,uuid)',
    'public.request_booking_approval(uuid,uuid,text,uuid)',
    'public.request_booking_cancellation(uuid,uuid,text,text,uuid)',
    'public.request_commercial_booking_approval(uuid,uuid,text,uuid)',
    'public.update_client_v1(uuid,uuid,text,text,text,text,text,text,text,integer,text,uuid)',
    'public.update_lead_v1(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamp with time zone,integer,text,uuid)',
    'public.update_operations_task_status(uuid,uuid,text,uuid)',
    'public.update_transport_request_status(uuid,uuid,text,uuid)'
  ];
BEGIN
  IF to_regprocedure('public.require_workspace_aal2_v1()') IS NULL THEN
    RAISE EXCEPTION 'workspace AAL2 guard is required before protecting business RPCs';
  END IF;

  FOREACH v_signature IN ARRAY v_protected_signatures LOOP
    v_function_oid := to_regprocedure(v_signature);
    IF v_function_oid IS NULL THEN
      RAISE EXCEPTION 'R01 protected RPC signature is missing: %', v_signature;
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

    -- The locals above carry different catalog types; read the security
    -- properties explicitly so this migration fails closed on drift.
    IF NOT (SELECT routine.prosecdef FROM pg_catalog.pg_proc AS routine WHERE routine.oid = v_function_oid)
      OR NOT EXISTS (
        SELECT 1
        FROM unnest(coalesce(
          (SELECT routine.proconfig FROM pg_catalog.pg_proc AS routine WHERE routine.oid = v_function_oid),
          ARRAY[]::text[]
        )) AS setting
        WHERE setting LIKE 'search_path=%'
      ) THEN
      RAISE EXCEPTION 'R01 RPC must remain SECURITY DEFINER with a pinned search_path: %', v_signature;
    END IF;
    IF NOT has_function_privilege('authenticated', v_function_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'R01 authenticated grant is missing for protected RPC: %', v_signature;
    END IF;
    IF has_function_privilege('anon', v_function_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'R01 RPC unexpectedly grants anon EXECUTE: %', v_signature;
    END IF;

    v_definition := pg_catalog.pg_get_functiondef(v_function_oid);
    IF position('PERFORM public.require_workspace_aal2_v1()' IN v_definition) > 0 THEN
      v_existing_aal2 := v_existing_aal2 + 1;
      CONTINUE;
    END IF;

    v_inner_name := v_function_name || '_without_workspace_aal2';
    IF length(v_inner_name) > 63 THEN
      RAISE EXCEPTION 'R01 private implementation name exceeds PostgreSQL limit: %', v_inner_name;
    END IF;

    SELECT string_agg(pg_catalog.format_type(argument_type, NULL), ', ' ORDER BY ordinal_position)
      INTO v_identity_types
    FROM unnest(v_input_types) WITH ORDINALITY AS input_argument(argument_type, ordinal_position);

    IF to_regprocedure(format('%I.%I(%s)', v_schema_name, v_inner_name, v_identity_types)) IS NOT NULL THEN
      RAISE EXCEPTION 'R01 private implementation name already exists: %.%', v_schema_name, v_inner_name;
    END IF;

    v_header_end := strpos(v_definition, 'AS $function$');
    IF v_header_end = 0 THEN
      RAISE EXCEPTION 'R01 RPC has an unsupported function definition format: %', v_signature;
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

    -- Preserve the authenticated API contract; the wrapper, unlike its
    -- private implementation, owns the assurance check.
    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION %I.%I(%s) TO authenticated',
      v_schema_name, v_function_name, v_identity_types
    );

    IF has_function_privilege('voya_outbox_worker', v_function_oid, 'EXECUTE') THEN
      v_worker_grants := v_worker_grants + 1;
    END IF;
    v_wrapped := v_wrapped + 1;
  END LOOP;

  IF v_wrapped < 45 OR v_existing_aal2 < 1 THEN
    RAISE EXCEPTION 'R01 inventory did not match expected checkout groups (wrapped %, already AAL2 %)',
      v_wrapped, v_existing_aal2;
  END IF;

  RAISE NOTICE 'R01 AAL2 guards installed on % RPC signatures; % already had AAL2; % retained worker grants',
    v_wrapped, v_existing_aal2, v_worker_grants;
END;
$migration$;
