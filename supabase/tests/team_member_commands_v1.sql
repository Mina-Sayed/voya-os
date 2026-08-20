-- Voya OS V1 team authorization and last-owner checks.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regprocedure('public.change_organization_member_role(uuid,uuid,text,uuid)') IS NULL
    OR to_regprocedure('public.suspend_organization_member(uuid,uuid,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'team lifecycle RPCs are missing';
  END IF;
  IF has_table_privilege('authenticated', 'public.organization_memberships', 'UPDATE') THEN
    RAISE EXCEPTION 'browser role must not update memberships directly';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.email', 'owner@example.test', false);

DO $$
DECLARE owner_membership uuid;
BEGIN
  SELECT id INTO owner_membership FROM public.organization_memberships
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111';
  BEGIN
    PERFORM public.change_organization_member_role('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', owner_membership, 'viewer', NULL);
    RAISE EXCEPTION 'last owner was downgraded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.suspend_organization_member('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', owner_membership, 'اختبار', NULL);
    RAISE EXCEPTION 'last owner was suspended';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.remove_organization_member('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', owner_membership, 'اختبار', NULL);
    RAISE EXCEPTION 'last owner was removed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;

SELECT public.invite_organization_member(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'operator@example.test', 'operator', repeat('a', 64), NULL
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.list_organization_invitations('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') AS invitation
    WHERE invitation.normalized_email = 'operator@example.test'
      AND invitation.role = 'operator'
  ) THEN
    RAISE EXCEPTION 'canonical operator invitation was not stored';
  END IF;
END;
$$;

RESET ROLE;

INSERT INTO auth.users (id, email, email_confirmed_at)
VALUES ('66666666-6666-4666-8666-666666666666', 'accepted@example.test', timezone('utc', now()))
ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email, email_confirmed_at = EXCLUDED.email_confirmed_at;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.email', 'owner@example.test', false);

DO $$
DECLARE
  invitation_id uuid;
  invitation_token text := repeat('c', 64);
  invited_user uuid := '66666666-6666-4666-8666-666666666666';
  accepted_membership uuid;
BEGIN
  invitation_id := public.invite_organization_member(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'accepted@example.test', 'operator', invitation_token, NULL
  );
  PERFORM set_config('request.jwt.claim.sub', invited_user::text, false);
  PERFORM set_config('request.jwt.claim.email', 'accepted@example.test', false);
  SELECT membership_id INTO accepted_membership
  FROM public.accept_organization_invitation(invitation_token, NULL);

  IF accepted_membership IS NULL
    OR (SELECT role FROM public.list_organization_members('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') WHERE id = accepted_membership) <> 'operator' THEN
    RAISE EXCEPTION 'invitation acceptance did not create canonical operator compatibility membership';
  END IF;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_invitations
    WHERE normalized_email = 'accepted@example.test' AND status = 'accepted'
  ) THEN
    RAISE EXCEPTION 'accepted invitation was not marked accepted';
  END IF;
END;
$$;

SELECT 'team member V1 tests passed' AS result;
