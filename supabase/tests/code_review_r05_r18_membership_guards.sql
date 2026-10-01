-- Focused regression proof for R05 and R18 in the 2026-09-29 code review.
-- Run against a disposable database after the complete migration chain and
-- tenancy_booking_foundation.sql have been applied.
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  v_accept oid := to_regprocedure('public.accept_organization_invitation(text,uuid)');
  v_create oid := to_regprocedure('public.create_organization(text,text,text,uuid)');
  v_role_change oid := to_regprocedure('public.change_organization_member_role_without_workspace_aal2(uuid,uuid,text,uuid)');
  v_accept_definition text;
  v_create_definition text;
  v_create_implementation text;
  v_role_change_definition text;
BEGIN
  IF v_accept IS NULL OR v_create IS NULL OR v_role_change IS NULL THEN
    RAISE EXCEPTION 'R05/R18 functions are missing';
  END IF;

  IF has_function_privilege('anon', v_accept, 'EXECUTE')
    OR NOT has_function_privilege('authenticated', v_accept, 'EXECUTE')
    OR has_function_privilege('anon', v_create, 'EXECUTE')
    OR NOT has_function_privilege('authenticated', v_create, 'EXECUTE') THEN
    RAISE EXCEPTION 'R05/R18 RPC grants must remain authenticated-only';
  END IF;

  SELECT pg_get_functiondef(v_accept) INTO v_accept_definition;
  SELECT pg_get_functiondef(v_create) INTO v_create_definition;
  SELECT pg_get_functiondef('public.create_organization_without_workspace_aal2_r01(text,text,text,uuid)'::regprocedure)
  INTO v_create_implementation;
  SELECT pg_get_functiondef(v_role_change) INTO v_role_change_definition;

  IF position('require_workspace_aal2_v1' IN v_role_change_definition) > 0 THEN
    RAISE EXCEPTION 'R05 role-change implementation should remain behind its AAL2 public wrapper';
  END IF;
  IF position('PERFORM public.require_workspace_aal2_v1()' IN pg_get_functiondef(
      to_regprocedure('public.change_organization_member_role(uuid,uuid,text,uuid)')
    )) = 0 THEN
    RAISE EXCEPTION 'R05 role changes lost the public AAL2 guard';
  END IF;
  IF position('PERFORM public.require_workspace_aal2_v1()' IN v_create_definition) = 0
    OR position('pg_catalog.hashtextextended(v_user_id::text, 0)' IN v_create_implementation) = 0
    OR position('WHERE user_id = v_user_id' IN v_create_implementation) = 0 THEN
    RAISE EXCEPTION 'R18 create_organization lost its per-user transaction lock';
  END IF;
END;
$$;

INSERT INTO auth.users (id, email, email_confirmed_at)
VALUES
  ('e5f10000-0000-4000-8000-000000000010', 'r05-owner@example.test', timezone('utc', now())),
  ('e5f10000-0000-4000-8000-000000000011', 'r05-target@example.test', timezone('utc', now())),
  ('e5f10000-0000-4000-8000-000000000020', 'r18-suspended@example.test', timezone('utc', now())),
  ('e5f10000-0000-4000-8000-000000000021', 'r18-mixed@example.test', timezone('utc', now())),
  ('e5f10000-0000-4000-8000-000000000022', 'r18-eligible@example.test', timezone('utc', now()))
ON CONFLICT (id) DO UPDATE
SET email = EXCLUDED.email,
    email_confirmed_at = EXCLUDED.email_confirmed_at;

INSERT INTO public.profiles (id, display_name)
VALUES
  ('e5f10000-0000-4000-8000-000000000010', 'R05 owner'),
  ('e5f10000-0000-4000-8000-000000000011', 'R05 target'),
  ('e5f10000-0000-4000-8000-000000000020', 'R18 suspended'),
  ('e5f10000-0000-4000-8000-000000000021', 'R18 mixed'),
  ('e5f10000-0000-4000-8000-000000000022', 'R18 eligible')
ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

INSERT INTO public.organizations (id, name, slug, default_locale, timezone, status)
VALUES
  ('e5f10000-0000-4000-8000-000000000101', 'R05 stale invitation', 'review-r05-stale-invitation', 'ar', 'Africa/Cairo', 'active'),
  ('e5f10000-0000-4000-8000-000000000102', 'R18 suspended membership', 'review-r18-suspended-membership', 'ar', 'Africa/Cairo', 'active'),
  ('e5f10000-0000-4000-8000-000000000103', 'R18 mixed active membership', 'review-r18-mixed-active-membership', 'ar', 'Africa/Cairo', 'active'),
  ('e5f10000-0000-4000-8000-000000000104', 'R18 mixed suspended membership', 'review-r18-mixed-suspended-membership', 'ar', 'Africa/Cairo', 'active')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.organization_memberships (id, organization_id, user_id, role, status)
VALUES
  ('e5f10000-0000-4000-8000-000000000201', 'e5f10000-0000-4000-8000-000000000101', 'e5f10000-0000-4000-8000-000000000010', 'owner', 'active'),
  ('e5f10000-0000-4000-8000-000000000202', 'e5f10000-0000-4000-8000-000000000101', 'e5f10000-0000-4000-8000-000000000011', 'manager', 'suspended'),
  ('e5f10000-0000-4000-8000-000000000203', 'e5f10000-0000-4000-8000-000000000102', 'e5f10000-0000-4000-8000-000000000020', 'viewer', 'suspended'),
  ('e5f10000-0000-4000-8000-000000000204', 'e5f10000-0000-4000-8000-000000000103', 'e5f10000-0000-4000-8000-000000000021', 'manager', 'active'),
  ('e5f10000-0000-4000-8000-000000000205', 'e5f10000-0000-4000-8000-000000000104', 'e5f10000-0000-4000-8000-000000000021', 'viewer', 'suspended')
ON CONFLICT (organization_id, user_id) DO UPDATE
SET role = EXCLUDED.role, status = EXCLUDED.status, updated_at = timezone('utc', now());

-- R05: use the real invitation, reactivation, and role-change commands to
-- reproduce a manager invite outliving the role state it originally described.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'e5f10000-0000-4000-8000-000000000010', false);
SELECT set_config('request.jwt.claim.email', 'r05-owner@example.test', false);
SELECT set_config('request.jwt.claims', '{"sub":"e5f10000-0000-4000-8000-000000000010","email":"r05-owner@example.test","role":"authenticated","aal":"aal2"}', false);
SELECT public.invite_organization_member_v1(
  'e5f10000-0000-4000-8000-000000000101',
  'r05-target@example.test',
  'manager',
  repeat('5', 64),
  'v1.sealed.iv.tag0000',
  NULL
);
SELECT public.reactivate_organization_member(
  'e5f10000-0000-4000-8000-000000000101',
  'e5f10000-0000-4000-8000-000000000202',
  NULL
);
SELECT public.change_organization_member_role(
  'e5f10000-0000-4000-8000-000000000101',
  'e5f10000-0000-4000-8000-000000000202',
  'owner',
  NULL
);
SELECT public.change_organization_member_role(
  'e5f10000-0000-4000-8000-000000000101',
  'e5f10000-0000-4000-8000-000000000201',
  'manager',
  NULL
);

SELECT set_config('request.jwt.claim.sub', 'e5f10000-0000-4000-8000-000000000011', false);
SELECT set_config('request.jwt.claim.email', 'r05-target@example.test', false);
SELECT set_config('request.jwt.claims', '{"sub":"e5f10000-0000-4000-8000-000000000011","email":"r05-target@example.test","role":"authenticated","aal":"aal2"}', false);
SELECT * FROM public.accept_organization_invitation(repeat('5', 64), NULL);
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.accept_organization_invitation(repeat('5', 64), NULL);
    RAISE EXCEPTION 'R05 accepted invitation replay unexpectedly succeeded' USING ERRCODE = 'P0001';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

DO $$
DECLARE
  v_target_role text;
  v_owner_count integer;
BEGIN
  SELECT membership.role INTO v_target_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = 'e5f10000-0000-4000-8000-000000000101'
    AND membership.user_id = 'e5f10000-0000-4000-8000-000000000011'
    AND membership.status = 'active';
  SELECT count(*) INTO v_owner_count
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = 'e5f10000-0000-4000-8000-000000000101'
    AND membership.status = 'active'
    AND membership.role = 'owner';
  IF v_target_role <> 'owner' OR v_owner_count <> 1 THEN
    RAISE EXCEPTION 'R05 regression: stale invitation changed an active promoted owner to %, leaving % active owners',
      coalesce(v_target_role, '<missing>'), v_owner_count;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_invitations AS invitation
    WHERE invitation.organization_id = 'e5f10000-0000-4000-8000-000000000101'
      AND invitation.normalized_email = 'r05-target@example.test'
      AND invitation.status = 'accepted'
  ) THEN
    RAISE EXCEPTION 'R05 invitation was not consumed after preserving the active role';
  END IF;
END;
$$;

DO $$
DECLARE
  v_accept_definition text := pg_get_functiondef(
    to_regprocedure('public.accept_organization_invitation(text,uuid)')
  );
  v_role_change_definition text := pg_get_functiondef(
    to_regprocedure('public.change_organization_member_role_without_workspace_aal2(uuid,uuid,text,uuid)')
  );
BEGIN
  IF position('pg_catalog.hashtextextended(p_organization_id::text, 1)' IN v_role_change_definition) = 0
    OR position('pg_catalog.hashtextextended(v_invitation.organization_id::text, 1)' IN v_accept_definition) = 0 THEN
    RAISE EXCEPTION 'R05 invitation acceptance and role changes must share the organization advisory lock';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'e5f10000-0000-4000-8000-000000000020', false);
SELECT set_config('request.jwt.claim.email', 'r18-suspended@example.test', false);
SELECT set_config('request.jwt.claims', '{"sub":"e5f10000-0000-4000-8000-000000000020","email":"r18-suspended@example.test","role":"authenticated","aal":"aal2"}', false);
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.create_organization('R18 suspended-only must be denied', 'Africa/Cairo', 'EGP', NULL);
    RAISE EXCEPTION 'R18 regression: all-suspended member created a replacement organization' USING ERRCODE = 'P0001';
  EXCEPTION WHEN SQLSTATE '23505' THEN
    NULL;
  END;
END;
$$;

SELECT set_config('request.jwt.claim.sub', 'e5f10000-0000-4000-8000-000000000021', false);
SELECT set_config('request.jwt.claim.email', 'r18-mixed@example.test', false);
SELECT set_config('request.jwt.claims', '{"sub":"e5f10000-0000-4000-8000-000000000021","email":"r18-mixed@example.test","role":"authenticated","aal":"aal2"}', false);
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.create_organization('R18 mixed memberships must be denied', 'Africa/Cairo', 'EGP', NULL);
    RAISE EXCEPTION 'R18 regression: mixed-status member created a replacement organization' USING ERRCODE = 'P0001';
  EXCEPTION WHEN SQLSTATE '23505' THEN
    NULL;
  END;
END;
$$;

SELECT set_config('request.jwt.claim.sub', 'e5f10000-0000-4000-8000-000000000022', false);
SELECT set_config('request.jwt.claim.email', 'r18-eligible@example.test', false);
SELECT set_config('request.jwt.claims', '{"sub":"e5f10000-0000-4000-8000-000000000022","email":"r18-eligible@example.test","role":"authenticated","aal":"aal1"}', false);
DO $$
DECLARE v_denied boolean := false;
BEGIN
  BEGIN
    PERFORM * FROM public.create_organization('R18 AAL1 must be denied', 'Africa/Cairo', 'EGP', NULL);
    RAISE EXCEPTION 'R01 regression: AAL1 created an organization' USING ERRCODE = 'P0001';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM NOT LIKE '%MFA AAL2 is required%' THEN RAISE; END IF;
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'R01 AAL1 organization provisioning was not denied'; END IF;
END;
$$;
SELECT set_config('request.jwt.claims', '{"sub":"e5f10000-0000-4000-8000-000000000022","email":"r18-eligible@example.test","role":"authenticated","aal":"aal2"}', false);
SELECT * FROM public.create_organization('R18 no prior membership remains eligible', 'Africa/Cairo', 'EGP', NULL);
RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.organization_memberships WHERE user_id = 'e5f10000-0000-4000-8000-000000000020') <> 1
    OR (SELECT count(*) FROM public.organization_memberships WHERE user_id = 'e5f10000-0000-4000-8000-000000000021') <> 2 THEN
    RAISE EXCEPTION 'R18 rejected provisioning changed existing membership counts';
  END IF;
  IF (SELECT count(*) FROM public.organization_memberships WHERE user_id = 'e5f10000-0000-4000-8000-000000000022' AND role = 'owner' AND status = 'active') <> 1 THEN
    RAISE EXCEPTION 'R18 user without prior membership could not self-provision exactly one owner membership';
  END IF;
END;
$$;

ROLLBACK;
SELECT 'R05 stale invitation and R18 prior-membership guards passed' AS result;
