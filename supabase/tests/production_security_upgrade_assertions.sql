-- Assertions run immediately after applying the remediation over the previous
-- schema plus representative existing rows.
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_invalid_constraints text[];
  v_legacy_function oid;
  v_legacy_definition text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.whatsapp_internal_notes
    WHERE id = 'aaaaaaaa-0000-0000-0000-000000000907'
      AND organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.operations_tasks
    WHERE id = 'aaaaaaaa-0000-0000-0000-000000000908'
      AND organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.transport_requests
    WHERE id = 'aaaaaaaa-0000-0000-0000-000000000911'
      AND status = 'assigned'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.auth_rate_limit_buckets
    WHERE scope = 'magic_link' AND key_hash = repeat('9', 64)
      AND attempt_count = 2
  ) OR NOT EXISTS (
    SELECT 1 FROM public.auth_rate_limit_buckets
    WHERE scope = 'password_sign_in' AND key_hash = repeat('8', 64)
      AND attempt_count = 3
  ) THEN
    RAISE EXCEPTION 'representative rows were not preserved by the forward migration';
  END IF;

  SELECT array_agg(constraint_record.conname ORDER BY constraint_record.conname)
  INTO v_invalid_constraints
  FROM pg_constraint AS constraint_record
  WHERE constraint_record.connamespace = 'public'::regnamespace
    AND constraint_record.conname IN (
      'crm_contact_method_lead_tenant_fk',
      'crm_contact_method_client_tenant_fk',
      'crm_consent_contact_method_tenant_fk',
      'whatsapp_conversation_contact_method_tenant_fk',
      'whatsapp_conversation_lead_tenant_fk',
      'whatsapp_conversation_client_tenant_fk',
      'whatsapp_message_conversation_tenant_fk',
      'whatsapp_note_conversation_tenant_fk',
      'operations_task_booking_tenant_fk'
    )
    AND NOT constraint_record.convalidated;

  IF v_invalid_constraints IS NOT NULL THEN
    RAISE EXCEPTION 'forward migration left constraints unvalidated: %', v_invalid_constraints;
  END IF;

  IF to_regclass('public.booking_command_idempotency') IS NULL
    OR to_regprocedure('public.consume_auth_rate_limit(text,text)') IS NULL THEN
    RAISE EXCEPTION 'forward migration did not install required objects';
  END IF;

  v_legacy_function := to_regprocedure('public.consume_auth_rate_limit(text,text,integer,integer)');
  IF v_legacy_function IS NULL THEN
    RAISE EXCEPTION 'rolling-deploy compatibility overload is missing';
  END IF;

  SELECT pg_get_functiondef(v_legacy_function)
  INTO v_legacy_definition;

  IF v_legacy_definition LIKE '%ON CONFLICT (key_hash)%'
    OR v_legacy_definition NOT LIKE '%auth rate-limit policy is database controlled%' THEN
    RAISE EXCEPTION 'legacy overload still contains caller-controlled policy logic';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc AS function_record
    WHERE function_record.oid = v_legacy_function
      AND function_record.prosecdef
      AND 'search_path=pg_catalog' = ANY (function_record.proconfig)
      AND NOT EXISTS (
        SELECT 1
        FROM aclexplode(function_record.proacl) AS privilege
        WHERE privilege.grantee = 0
          AND privilege.privilege_type = 'EXECUTE'
      )
  ) THEN
    RAISE EXCEPTION 'legacy overload security mode or ACL is unsafe';
  END IF;

  IF NOT has_function_privilege('anon', v_legacy_function, 'EXECUTE')
    OR NOT has_function_privilege('authenticated', v_legacy_function, 'EXECUTE')
    OR NOT has_function_privilege('service_role', v_legacy_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'compatibility overload lost an intended execution grant';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE anon;
SELECT public.consume_auth_rate_limit('magic_link', repeat('d', 64), 5, 900);
ROLLBACK;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT public.consume_auth_rate_limit('password_sign_in', repeat('e', 64), 10, 900);
ROLLBACK;

DO $$
DECLARE
  v_key_hash text := repeat('f', 64);
BEGIN
  IF NOT public.consume_auth_rate_limit('magic_link', v_key_hash, 5, 900) THEN
    RAISE EXCEPTION 'exact legacy compatibility policy should delegate to the canonical function';
  END IF;

  BEGIN
    PERFORM public.consume_auth_rate_limit('magic_link', v_key_hash, 1000, 1);
    RAISE EXCEPTION 'caller-controlled legacy policy was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  BEGIN
    PERFORM public.consume_auth_rate_limit('password_sign_up', repeat('a', 64), 1, 1);
    RAISE EXCEPTION 'unsupported password-signup policy was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
END;
$$;

SELECT 'production security forward-upgrade test passed' AS result;
