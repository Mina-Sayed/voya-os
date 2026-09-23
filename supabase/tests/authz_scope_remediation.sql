-- Regression proofs for the cross-tenant, MFA, assignment, and CRM-scope fixes.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF has_function_privilege('anon', 'public.change_organization_member_role(uuid,uuid,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.update_operations_task_status(uuid,uuid,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'sensitive Auth/AuthZ RPCs must not be executable by anon';
  END IF;
END;
$$;

-- The old lead RPC must fail closed when the caller has no membership in the
-- selected organization. This is the NULL NOT IN cross-tenant regression.
INSERT INTO public.leads (id, organization_id, title, name, source, status, idempotency_key)
VALUES (
  'aaaaaaaa-0000-0000-0000-000000000a01',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'Tenant A private lead', 'Tenant A private lead', 'website', 'new', 'authz-lead-scope-1'
)
ON CONFLICT (id) DO NOTHING;

UPDATE public.leads AS lead_record
SET assigned_membership_id = owner_membership.id
FROM public.organization_memberships AS owner_membership
WHERE lead_record.id = 'aaaaaaaa-0000-0000-0000-000000000a01'
  AND owner_membership.organization_id = lead_record.organization_id
  AND owner_membership.user_id = '11111111-1111-1111-1111-111111111111';

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_leads('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'cross-tenant legacy lead read was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

-- Team administration must be database-gated, not only Server-Action-gated.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal1', false);
DO $$
DECLARE v_owner uuid;
BEGIN
  SELECT id INTO v_owner FROM public.organization_memberships
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND user_id = '11111111-1111-1111-1111-111111111111';
  BEGIN
    PERFORM public.list_organization_members('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'AAL1 team read was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.change_organization_member_role(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_owner, 'viewer', NULL
    );
    RAISE EXCEPTION 'AAL1 team mutation was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

-- Seed an operations member, an owner-assigned task, and a lead-owned follow-up.
INSERT INTO auth.users (id, email, email_confirmed_at)
VALUES
  ('77777777-7777-4777-8777-777777777777', 'operations-scope@example.test', timezone('utc', now())),
  ('88888888-8888-4888-8888-888888888888', 'sales-scope@example.test', timezone('utc', now()))
ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email, email_confirmed_at = EXCLUDED.email_confirmed_at;

INSERT INTO public.profiles (id, display_name)
VALUES
  ('77777777-7777-4777-8777-777777777777', 'Operations scope user'),
  ('88888888-8888-4888-8888-888888888888', 'Sales scope user')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '77777777-7777-4777-8777-777777777777', 'operations', 'active'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '88888888-8888-4888-8888-888888888888', 'sales_agent', 'active')
ON CONFLICT DO NOTHING;

INSERT INTO public.operations_tasks (
  id, organization_id, task_type, title, status, assigned_membership_id,
  created_by_membership_id, idempotency_key
)
SELECT
  'aaaaaaaa-0000-0000-0000-000000000a02',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'scope_test', 'Owner assigned task', 'open', owner_membership.id,
  owner_membership.id, 'authz-task-scope-1'
FROM public.organization_memberships AS owner_membership
WHERE owner_membership.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND owner_membership.user_id = '11111111-1111-1111-1111-111111111111'
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.crm_follow_ups (
  id, organization_id, lead_id, due_at, note, idempotency_key
)
VALUES (
  'aaaaaaaa-0000-0000-0000-000000000a03',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000a01',
  timezone('utc', now()) + interval '1 day', 'Owner lead follow-up', 'authz-follow-up-scope-1'
)
ON CONFLICT (id) DO NOTHING;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '77777777-7777-4777-8777-777777777777', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
BEGIN
  IF (SELECT count(*) FROM public.list_operations_tasks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 100)
      WHERE id = 'aaaaaaaa-0000-0000-0000-000000000a02') <> 0 THEN
    RAISE EXCEPTION 'operations member can read another member task';
  END IF;
  BEGIN
    PERFORM public.update_operations_task_status(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000a02', 'completed', NULL
    );
    RAISE EXCEPTION 'operations member changed another member task';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '88888888-8888-4888-8888-888888888888', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_lead_activities_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000a01'
    );
    RAISE EXCEPTION 'sales agent read activity on another agent lead';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.create_lead_activity_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000a01', 'note',
      'Unauthorized activity', 'authz-activity-scope-1', NULL
    );
    RAISE EXCEPTION 'sales agent created activity on another agent lead';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.complete_lead_follow_up_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000a03',
      NULL, 'authz-follow-up-complete-1', NULL
    );
    RAISE EXCEPTION 'sales agent completed follow-up on another agent lead';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

-- AAL2 owner oversight remains intact after the wrappers are installed.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
SELECT public.update_operations_task_status(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000a02', 'completed', NULL
);
RESET ROLE;

SELECT 'Auth/AuthZ scope remediation tests passed' AS result;
