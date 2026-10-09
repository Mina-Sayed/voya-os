-- R01: direct authenticated RPC calls must enforce workspace MFA in the
-- database, including the final overloads for booking, CRM, transport, tasks,
-- and onboarding. Invitation acceptance intentionally remains pre-workspace.
\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.require_workspace_aal2_v1()') IS NULL THEN
    RAISE EXCEPTION 'workspace AAL2 guard is missing';
  END IF;
END;
$$;

-- Exercise every authenticated RPC overload in the protected business groups.
-- Typed NULL arguments deliberately make each original command reach its own
-- authorization/validation path; only the MFA guard's 42501 is accepted.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.email', 'owner@example.test', false);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal1"}',
  false
);

-- Reproduce the reported high-risk command with a valid tenant and resource:
-- before the repair an authenticated AAL1 owner can create a commercial draft.
DO $$
DECLARE
  v_booking_id uuid;
  v_sqlstate text;
BEGIN
  BEGIN
    v_booking_id := public.create_commercial_booking_draft(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000002',
      DATE '2088-01-10', DATE '2088-01-12', '125000', 'EGP', 'r01-aal1-reproduction',
      'aaaaaaaa-0000-0000-0000-000000000780'
    );
    RAISE EXCEPTION 'R01 regression: AAL1 created commercial booking %', v_booking_id;
  EXCEPTION WHEN SQLSTATE '42501' THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate <> '42501' OR SQLERRM NOT LIKE '%MFA AAL2 is required%' THEN
      RAISE EXCEPTION 'AAL1 commercial booking was denied for another reason: % (%)', SQLERRM, v_sqlstate;
    END IF;
  END;
END;
$$;

DO $$
DECLARE
  v_function record;
  v_arguments text;
  v_invocation text;
  v_count integer := 0;
  v_sqlstate text;
BEGIN
  FOR v_function IN
    SELECT p.oid, p.proname, p.proargtypes, p.prosecdef, p.proconfig
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.prorettype <> 'trigger'::regtype
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND p.proname ~ '(booking|approval|lead|client|crm|transport|fleet|operations_task|onboarding)'
      AND p.proname NOT IN ('crm_normalize_email', 'crm_normalize_phone', 'reject_self_approval')
    ORDER BY p.proname, p.oid::regprocedure::text
  LOOP
    SELECT string_agg(
      format('NULL::%s', pg_catalog.format_type(argument_type, NULL)),
      ', ' ORDER BY ordinal_position
    )
    INTO v_arguments
    FROM unnest(v_function.proargtypes) WITH ORDINALITY AS argument(argument_type, ordinal_position);

    v_invocation := format(
      'SELECT * FROM public.%I(%s)',
      v_function.proname,
      coalesce(v_arguments, '')
    );

    BEGIN
      EXECUTE v_invocation;
      RAISE EXCEPTION 'R01 AAL1 direct RPC call unexpectedly succeeded: %', v_function.oid::regprocedure;
    EXCEPTION WHEN SQLSTATE '42501' THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      IF v_sqlstate <> '42501' OR SQLERRM NOT LIKE '%MFA AAL2 is required%' THEN
        RAISE EXCEPTION 'R01 AAL1 call reached a non-MFA denial at %: % (%)',
          v_function.oid::regprocedure, SQLERRM, v_sqlstate;
      END IF;
    END;

    v_count := v_count + 1;
  END LOOP;

  IF v_count < 50 THEN
    RAISE EXCEPTION 'R01 RPC inventory unexpectedly small; only checked % signatures', v_count;
  END IF;

  RAISE NOTICE 'R01 AAL1 denial proved for % authenticated RPC signatures', v_count;
END;
$$;

RESET ROLE;

INSERT INTO auth.users (id, email)
VALUES ('99999999-9999-9999-9999-999999999999', 'r01-approver@example.test')
ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email;

INSERT INTO public.profiles (id, display_name)
VALUES ('99999999-9999-9999-9999-999999999999', 'R01 approver')
ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '99999999-9999-9999-9999-999999999999', 'manager', 'active'
)
ON CONFLICT (organization_id, user_id) DO UPDATE
SET role = EXCLUDED.role, status = EXCLUDED.status, updated_at = timezone('utc', now());

-- Check final definitions and grants, including functions with multiple
-- overloads. The protected implementations stay SECURITY DEFINER, while the
-- pre-AAL2 implementation names cannot be invoked by browser roles.
DO $$
DECLARE
  v_function record;
  v_count integer := 0;
BEGIN
  FOR v_function IN
    SELECT p.oid, p.prosecdef, p.proconfig, pg_get_functiondef(p.oid) AS definition
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.prorettype <> 'trigger'::regtype
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND p.proname ~ '(booking|approval|lead|client|crm|transport|fleet|operations_task|onboarding)'
      AND p.proname NOT IN ('crm_normalize_email', 'crm_normalize_phone', 'reject_self_approval')
  LOOP
    IF NOT v_function.prosecdef
      OR NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(v_function.proconfig, ARRAY[]::text[])) AS setting
        WHERE setting LIKE 'search_path=%'
      ) THEN
      RAISE EXCEPTION 'R01 protected RPC must remain SECURITY DEFINER with a pinned search_path: %',
        v_function.oid::regprocedure;
    END IF;
    IF position('PERFORM public.require_workspace_aal2_v1()' IN v_function.definition) = 0 THEN
      RAISE EXCEPTION 'R01 final RPC definition lacks the database AAL2 guard: %',
        v_function.oid::regprocedure;
    END IF;
    IF has_function_privilege('anon', v_function.oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'R01 protected RPC must not be executable by anon: %', v_function.oid::regprocedure;
    END IF;
    v_count := v_count + 1;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname LIKE '%\_without_workspace_aal2' ESCAPE '\'
      AND (
        has_function_privilege('authenticated', p.oid, 'EXECUTE')
        OR has_function_privilege('anon', p.oid, 'EXECUTE')
      )
  ) THEN
    RAISE EXCEPTION 'authenticated must not execute pre-AAL2 internal implementations';
  END IF;

  IF v_count < 50 THEN
    RAISE EXCEPTION 'R01 final definition audit unexpectedly small; only checked % signatures', v_count;
  END IF;

  RAISE NOTICE 'R01 final AAL2 definitions and anon grants proved for % RPC signatures', v_count;
END;
$$;

-- The current final ACL inventory gives these human workspace groups no
-- service_role or outbox-worker grant. Those privileged grants stay on their
-- separate worker RPCs and must not be introduced by this repair.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND routine.prokind = 'f'
      AND routine.prorettype <> 'trigger'::regtype
      AND has_function_privilege('authenticated', routine.oid, 'EXECUTE')
      AND routine.proname ~ '(booking|approval|lead|client|crm|transport|fleet|operations_task|onboarding)'
      AND routine.proname NOT IN ('crm_normalize_email', 'crm_normalize_phone', 'reject_self_approval')
      AND (
        has_function_privilege('service_role', routine.oid, 'EXECUTE')
        OR has_function_privilege('voya_outbox_worker', routine.oid, 'EXECUTE')
      )
  ) THEN
    RAISE EXCEPTION 'R01 repair broadened service_role/outbox-worker grants on human RPC groups';
  END IF;
END;
$$;

-- AAL2 sessions keep working through representative calls in every group and
-- through the complete booking approval/stay path.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.email', 'owner@example.test', false);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal2"}',
  false
);

-- Send the same typed direct calls through AAL2 for every protected signature.
-- Domain validation may still reject NULL test inputs; the workspace MFA guard
-- must let the authenticated AAL2 session reach that existing validation.
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
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.prorettype <> 'trigger'::regtype
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND p.proname ~ '(booking|approval|lead|client|crm|transport|fleet|operations_task|onboarding)'
      AND p.proname NOT IN ('crm_normalize_email', 'crm_normalize_phone', 'reject_self_approval')
    ORDER BY p.proname, p.oid::regprocedure::text
  LOOP
    SELECT string_agg(
      format('NULL::%s', pg_catalog.format_type(argument_type, NULL)),
      ', ' ORDER BY ordinal_position
    )
    INTO v_arguments
    FROM unnest(v_function.proargtypes) WITH ORDINALITY AS argument(argument_type, ordinal_position);

    v_invocation := format('SELECT * FROM public.%I(%s)', v_function.proname, coalesce(v_arguments, ''));
    BEGIN
      EXECUTE v_invocation;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
      IF v_message LIKE '%MFA AAL2 is required%' THEN
        RAISE EXCEPTION 'R01 AAL2 direct RPC call was blocked at %: %',
          v_function.oid::regprocedure, v_message;
      END IF;
    END;
    v_count := v_count + 1;
  END LOOP;

  IF v_count < 50 THEN
    RAISE EXCEPTION 'R01 AAL2 inventory unexpectedly small; only checked % signatures', v_count;
  END IF;
  RAISE NOTICE 'R01 AAL2 guard allowed access to existing validation for % RPC signatures', v_count;
END;
$$;

SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2055-01-10', DATE '2055-01-12', '125000', 'EGP', 'r01-commercial-draft',
  'aaaaaaaa-0000-0000-0000-000000000781'
) AS r01_booking_id \gset

SELECT public.request_commercial_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'r01_booking_id', 'r01-commercial-approval',
  'aaaaaaaa-0000-0000-0000-000000000782'
) AS r01_approval_id \gset

SELECT public.create_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'R01 AAL2 Lead', '+201000000781', NULL,
  'r01-aal2-lead@example.test', 'website', 'new', NULL, NULL,
  DATE '2055-02-01', DATE '2055-02-03', 2, 1, NULL, NULL, NULL,
  'r01-aal2-crm-lead', 'aaaaaaaa-0000-0000-0000-000000000783'
) AS r01_lead_id \gset

SELECT public.create_operations_task(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'r01_aal2', 'R01 AAL2 task', NULL,
  NULL, NULL, NULL, 'r01-aal2-task', 'aaaaaaaa-0000-0000-0000-000000000784'
) AS r01_task_id \gset

SELECT public.create_fleet_vehicle_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'R01 AAL2 vehicle', 'van', 'R01-AAL2-1', 4,
  'r01-aal2-vehicle', 'aaaaaaaa-0000-0000-0000-000000000785'
) AS r01_vehicle_id \gset

SELECT public.create_fleet_driver_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'R01 AAL2 driver', '+201000000782',
  'r01-aal2-driver', 'aaaaaaaa-0000-0000-0000-000000000786'
) AS r01_driver_id \gset

SELECT public.create_transport_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'airport_transfer', 'R01 AAL2 guest',
  'Cairo Airport', 'Tenant A property', TIMESTAMPTZ '2055-01-09 12:00:00+00',
  2, NULL, :'r01_booking_id', NULL, 'r01-aal2-transport',
  'aaaaaaaa-0000-0000-0000-000000000787'
) AS r01_transport_request_id \gset

SELECT count(*) FROM public.list_leads_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT count(*) FROM public.list_operations_tasks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 50);
SELECT count(*) FROM public.list_transport_requests('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 50);
SELECT count(*) FROM public.list_approval_requests_v2('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 50);
SELECT public.complete_organization_onboarding(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Tenant A', 'Africa/Cairo', 'EGP',
  'aaaaaaaa-0000-0000-0000-000000000788'
);

RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', false);
SELECT set_config('request.jwt.claim.email', 'r01-approver@example.test', false);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"99999999-9999-9999-9999-999999999999","email":"r01-approver@example.test","role":"authenticated","aal":"aal2"}',
  false
);

SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'r01_approval_id', 'approved',
  'R01 AAL2 independent review', 'aaaaaaaa-0000-0000-0000-000000000790'
);
SELECT public.confirm_commercial_booking(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'r01_booking_id', 'r01-commercial-confirm',
  'aaaaaaaa-0000-0000-0000-000000000791'
);
SELECT public.record_commercial_booking_stay_event(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'r01_booking_id', 'check_in', NULL,
  'r01-commercial-stay-event', 'aaaaaaaa-0000-0000-0000-000000000792'
);

RESET ROLE;

INSERT INTO auth.users (id, email)
VALUES ('88888888-8888-8888-8888-888888888888', 'r01-invitee@example.test')
ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email;

INSERT INTO public.organization_invitations (
  organization_id, normalized_email, role, token_digest, expires_at, created_by_membership_id
)
SELECT
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'r01-invitee@example.test', 'operator',
  encode(extensions.digest(repeat('a', 64), 'sha256'), 'hex'),
  timezone('utc', now()) + interval '1 day', membership.id
FROM public.organization_memberships AS membership
WHERE membership.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND membership.user_id = '11111111-1111-1111-1111-111111111111'
  AND membership.status = 'active'
ON CONFLICT DO NOTHING;

-- Invitation acceptance is intentionally AAL1 before workspace entry.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '88888888-8888-8888-8888-888888888888', false);
SELECT set_config('request.jwt.claim.email', 'r01-invitee@example.test', false);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"88888888-8888-8888-8888-888888888888","email":"r01-invitee@example.test","role":"authenticated","aal":"aal1"}',
  false
);

DO $$
DECLARE
  v_organization_id uuid;
  v_membership_id uuid;
BEGIN
  SELECT acceptance.organization_id, acceptance.membership_id
    INTO v_organization_id, v_membership_id
  FROM public.accept_organization_invitation(
    repeat('a', 64), 'aaaaaaaa-0000-0000-0000-000000000789'
  ) AS acceptance;
  IF v_organization_id <> 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    OR v_membership_id IS NULL THEN
    RAISE EXCEPTION 'pre-workspace AAL1 invitation acceptance must remain available';
  END IF;
END;
$$;

RESET ROLE;

ROLLBACK;

SELECT 'workspace RPC AAL2 closure tests passed' AS result;
