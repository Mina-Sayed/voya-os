-- Voya OS V1 onboarding/team contract assertions.
DO $$
BEGIN
  IF to_regclass('public.organization_invitations') IS NULL THEN
    RAISE EXCEPTION 'organization_invitations table is missing';
  END IF;
  IF to_regprocedure('public.create_organization(text,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'create_organization RPC is missing';
  END IF;
  IF to_regprocedure('public.complete_organization_onboarding(uuid,text,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'complete_organization_onboarding RPC is missing';
  END IF;
  IF to_regprocedure('public.invite_organization_member(uuid,text,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'invite_organization_member RPC is missing';
  END IF;
  IF to_regprocedure('public.invite_organization_member_v1(uuid,text,text,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'invite_organization_member_v1 RPC is missing';
  END IF;
  IF to_regprocedure('public.accept_organization_invitation(text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'accept_organization_invitation RPC is missing';
  END IF;
  IF to_regprocedure('public.consume_auth_rate_limit(text,text,integer,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'legacy caller-parameterized rate-limit overload remains';
  END IF;
END;
$$;

DO $$
DECLARE
  invitation_rls boolean;
BEGIN
  SELECT relrowsecurity INTO invitation_rls
  FROM pg_class
  WHERE oid = 'public.organization_invitations'::regclass;
  IF invitation_rls IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'organization invitations must have RLS enabled';
  END IF;
END;
$$;

DO $$
DECLARE
  invitation_token text := repeat('b', 64);
  invitation_sealed text := 'v1.sealed.iv.tag0000';
  invitation_id uuid;
  stored_digest text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
  PERFORM set_config('request.jwt.claim.email', 'owner@example.test', false);
  invitation_id := public.invite_organization_member_v1(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'invited@example.test',
    'operator',
    invitation_token,
    invitation_sealed,
    NULL
  );
  SELECT token_digest INTO stored_digest
  FROM public.organization_invitations
  WHERE id = invitation_id;
  IF stored_digest = invitation_token OR stored_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invitation raw token was persisted instead of its digest';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.outbox_events
    WHERE event_type = 'organization.invitation.send_requested'
      AND payload->>'invitation_id' = invitation_id::text
      AND payload->>'sealed_token' = invitation_sealed
      AND NOT (payload ? 'token')
  ) THEN
    RAISE EXCEPTION 'invitation delivery outbox event is missing';
  END IF;
END;
$$;
