-- Disposable coverage for the historical managed self-service bootstrap RPC.
-- This test intentionally documents the existing deterministic-slug collision
-- behavior; product/security policy must decide whether that capability remains.
\set ON_ERROR_STOP on

DO $$
DECLARE
  bootstrap_function oid := to_regprocedure('public.bootstrap_personal_workspace(uuid)');
BEGIN
  IF bootstrap_function IS NULL THEN
    RAISE EXCEPTION 'bootstrap_personal_workspace function is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc AS function_record
    WHERE function_record.oid = bootstrap_function
      AND function_record.prosecdef
      AND 'search_path=pg_catalog, public' = ANY (function_record.proconfig)
      AND NOT EXISTS (
        SELECT 1
        FROM aclexplode(coalesce(function_record.proacl, acldefault('f', function_record.proowner))) AS privilege
        WHERE privilege.grantee = 0
          AND privilege.privilege_type = 'EXECUTE'
      )
  ) THEN
    RAISE EXCEPTION 'bootstrap RPC must be SECURITY DEFINER, fixed-search-path, and non-PUBLIC';
  END IF;

  IF has_function_privilege('anon', bootstrap_function, 'EXECUTE')
    OR NOT has_function_privilege('authenticated', bootstrap_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'bootstrap RPC grants do not match the historical managed contract';
  END IF;
END;
$$;

INSERT INTO auth.users (id, email, email_confirmed_at)
VALUES
  ('77777777-7777-4777-8777-777777777777', 'bootstrap-a@example.test', timezone('utc', now())),
  ('88888888-8888-4888-8888-888888888888', 'bootstrap-b@example.test', timezone('utc', now())),
  ('99999999-9999-4999-8999-999999999999', 'bootstrap-c@example.test', timezone('utc', now()))
ON CONFLICT (id) DO UPDATE
SET email = EXCLUDED.email,
    email_confirmed_at = EXCLUDED.email_confirmed_at;

SET ROLE anon;
SELECT set_config('request.jwt.claim.sub', '77777777-7777-4777-8777-777777777777', false);
SELECT set_config('request.jwt.claim.email', 'bootstrap-a@example.test', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.bootstrap_personal_workspace(NULL);
    RAISE EXCEPTION 'anonymous caller executed the bootstrap RPC';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '77777777-7777-4777-8777-777777777777', false);
SELECT set_config('request.jwt.claim.email', 'bootstrap-a@example.test', false);
DO $$
DECLARE
  first_result record;
  caller_id uuid := NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
BEGIN
  SELECT * INTO first_result
  FROM public.bootstrap_personal_workspace('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

  BEGIN
    PERFORM public.bootstrap_personal_workspace('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    RAISE EXCEPTION 'bootstrap replay was allowed for a user with an existing membership';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  IF first_result.organization_id IS NULL OR first_result.membership_id IS NULL THEN
    RAISE EXCEPTION 'bootstrap returned incomplete identifiers';
  END IF;

  IF (SELECT slug FROM public.organizations WHERE id = first_result.organization_id)
      <> 'workspace-77777777777747778777777777777777' THEN
    RAISE EXCEPTION 'bootstrap organization slug is not deterministic for user A';
  END IF;

  IF (SELECT count(*) FROM public.profiles WHERE id = caller_id) <> 1
    OR (SELECT count(*) FROM public.profiles
        WHERE id = '88888888-8888-4888-8888-888888888888') <> 0 THEN
    RAISE EXCEPTION 'bootstrap profile access crossed the authenticated user boundary';
  END IF;

  IF (SELECT count(*)
      FROM public.organization_memberships AS membership
      WHERE membership.organization_id = first_result.organization_id
        AND membership.user_id = caller_id
        AND membership.role = 'owner'
        AND membership.status = 'active') <> 1 THEN
    RAISE EXCEPTION 'bootstrap did not create exactly one fixed owner membership';
  END IF;

  IF (SELECT count(*)
      FROM public.organization_memberships AS membership
      WHERE membership.user_id = caller_id) <> 1 THEN
    RAISE EXCEPTION 'bootstrap created more than the single expected membership for user A';
  END IF;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '88888888-8888-4888-8888-888888888888', false);
SELECT set_config('request.jwt.claim.email', 'bootstrap-b@example.test', false);
DO $$
DECLARE
  result record;
  caller_id uuid := NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
BEGIN
  -- The request id is deliberately unrelated to the caller's organization.
  SELECT * INTO result
  FROM public.bootstrap_personal_workspace('77777777-7777-4777-8777-777777777777');

  IF result.organization_id = (
    SELECT organization.id
    FROM public.organizations AS organization
    WHERE organization.slug = 'workspace-77777777777747778777777777777777'
  ) THEN
    RAISE EXCEPTION 'caller-controlled request input attached user B to user A organization';
  END IF;

  IF (SELECT slug FROM public.organizations WHERE id = result.organization_id)
      <> 'workspace-88888888888848888888888888888888' THEN
    RAISE EXCEPTION 'bootstrap organization slug is not deterministic for user B';
  END IF;

  IF (SELECT count(*)
      FROM public.profiles
      WHERE id = '77777777-7777-4777-8777-777777777777') <> 0
    OR (SELECT count(*)
        FROM public.organization_memberships AS membership
        JOIN public.organizations AS organization ON organization.id = membership.organization_id
        WHERE organization.slug = 'workspace-77777777777747778777777777777777'
          AND membership.user_id = caller_id) <> 0 THEN
    RAISE EXCEPTION 'user B can see or claim user A identity/workspace';
  END IF;

  IF (SELECT count(*)
      FROM public.organization_memberships AS membership
      WHERE membership.organization_id = result.organization_id
        AND membership.user_id = caller_id
        AND membership.role = 'owner'
        AND membership.status = 'active') <> 1 THEN
    RAISE EXCEPTION 'user B did not receive exactly one fixed owner membership';
  END IF;

  IF (SELECT count(*)
      FROM public.organization_memberships AS membership
      WHERE membership.user_id = caller_id) <> 1 THEN
    RAISE EXCEPTION 'bootstrap created more than the single expected membership for user B';
  END IF;
END;
$$;
RESET ROLE;

-- Seed an organization owned by A with C's deterministic slug. The historical
-- function resolves the conflict and grants C an owner membership in A's org;
-- this is the expected unresolved collision behavior, not a policy decision.
INSERT INTO public.organizations (id, name, slug, default_locale, timezone, status)
VALUES (
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  'Pre-existing collision workspace',
  'workspace-99999999999949998999999999999999',
  'ar', 'Africa/Cairo', 'active'
);
INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES (
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  '77777777-7777-4777-8777-777777777777',
  'owner', 'active'
);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '99999999-9999-4999-8999-999999999999', false);
SELECT set_config('request.jwt.claim.email', 'bootstrap-c@example.test', false);
DO $$
DECLARE
  collision_result record;
  caller_id uuid := NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
BEGIN
  SELECT * INTO collision_result
  FROM public.bootstrap_personal_workspace('cccccccc-cccc-4ccc-8ccc-cccccccccccc');

  IF collision_result.organization_id <> 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'::uuid THEN
    RAISE EXCEPTION 'historical slug collision behavior changed; update the explicit bootstrap policy test';
  END IF;
  RAISE NOTICE 'EXPECTED UNRESOLVED SECURITY FINDING: deterministic slug collision attached user C to a pre-existing organization';

  IF (SELECT count(*) FROM public.profiles WHERE id = caller_id) <> 1 THEN
    RAISE EXCEPTION 'collision bootstrap did not create the caller profile';
  END IF;
END;
$$;
RESET ROLE;

DO $$
DECLARE
  a_slug text := 'workspace-77777777777747778777777777777777';
  b_slug text := 'workspace-88888888888848888888888888888888';
BEGIN
  IF (SELECT count(*) FROM public.organizations WHERE slug IN (a_slug, b_slug)) <> 2
    OR (SELECT count(*)
        FROM public.organization_memberships AS membership
        JOIN public.organizations AS organization
          ON organization.id = membership.organization_id
        WHERE membership.user_id IN (
          '77777777-7777-4777-8777-777777777777',
          '88888888-8888-4888-8888-888888888888'
        )
          AND organization.slug IN (a_slug, b_slug)
          AND membership.role = 'owner'
          AND membership.status = 'active') <> 2
    OR (SELECT count(*)
        FROM public.audit_events AS audit
        JOIN public.organizations AS organization ON organization.id = audit.organization_id
        WHERE audit.action = 'organization.bootstrap'
          AND organization.slug IN (a_slug, b_slug)) <> 2 THEN
    RAISE EXCEPTION 'bootstrap replay created duplicate organizations, memberships, or audit facts';
  END IF;

  IF (SELECT count(*)
      FROM public.organization_memberships
      WHERE organization_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        AND user_id = '99999999-9999-4999-8999-999999999999') <> 1 THEN
    RAISE EXCEPTION 'expected unresolved slug collision membership was not recorded';
  END IF;
END;
$$;

SELECT 'self-service workspace bootstrap database integration tests passed (slug collision remains an expected unresolved policy finding)' AS result;
