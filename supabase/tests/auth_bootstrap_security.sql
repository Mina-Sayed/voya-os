-- The database is the final bootstrap guard even when an application caller is stale.
\set ON_ERROR_STOP on

INSERT INTO auth.users (id, email, email_confirmed_at)
VALUES
  ('44444444-4444-4444-4444-444444444444', 'unconfirmed@example.test', NULL),
  ('55555555-5555-5555-5555-555555555555', 'confirmed@example.test', timezone('utc', now())),
  ('66666666-6666-6666-6666-666666666666', 'suspended@example.test', timezone('utc', now()))
ON CONFLICT (id) DO UPDATE
SET email = EXCLUDED.email,
    email_confirmed_at = EXCLUDED.email_confirmed_at;

INSERT INTO public.profiles (id, display_name)
VALUES ('66666666-6666-6666-6666-666666666666', 'Suspended bootstrap user');

INSERT INTO public.organizations (id, name, slug)
VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Suspended tenant', 'suspended-bootstrap-tenant');

INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES (
  'cccccccc-cccc-cccc-cccc-cccccccccccc',
  '66666666-6666-6666-6666-666666666666',
  'viewer',
  'suspended'
);

SET ROLE authenticated;

SELECT set_config('request.jwt.claim.sub', '44444444-4444-4444-4444-444444444444', false);
SELECT set_config('request.jwt.claim.email', 'unconfirmed@example.test', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.bootstrap_personal_workspace('44444444-0000-0000-0000-000000000001');
    RAISE EXCEPTION 'unconfirmed user unexpectedly bootstrapped a workspace';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

SELECT set_config('request.jwt.claim.sub', '66666666-6666-6666-6666-666666666666', false);
SELECT set_config('request.jwt.claim.email', 'suspended@example.test', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.bootstrap_personal_workspace('66666666-0000-0000-0000-000000000001');
    RAISE EXCEPTION 'existing suspended member unexpectedly bootstrapped a workspace';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
SELECT set_config('request.jwt.claim.email', 'confirmed@example.test', false);
DO $$
DECLARE
  v_organization_id uuid;
  v_membership_id uuid;
BEGIN
  SELECT organization_id, membership_id
  INTO v_organization_id, v_membership_id
  FROM public.bootstrap_personal_workspace('55555555-0000-0000-0000-000000000001');

  IF v_organization_id IS NULL OR v_membership_id IS NULL THEN
    RAISE EXCEPTION 'confirmed new user did not receive a workspace membership';
  END IF;
END;
$$;

RESET ROLE;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.organization_memberships
    WHERE user_id = '44444444-4444-4444-4444-444444444444'
  ) THEN
    RAISE EXCEPTION 'unconfirmed bootstrap created a membership';
  END IF;
  IF (SELECT count(*) FROM public.organization_memberships
      WHERE user_id = '66666666-6666-6666-6666-666666666666') <> 1 THEN
    RAISE EXCEPTION 'suspended bootstrap changed membership state';
  END IF;
  IF (SELECT count(*) FROM public.organization_memberships
      WHERE user_id = '55555555-5555-5555-5555-555555555555'
        AND status = 'active' AND role = 'owner') <> 1 THEN
    RAISE EXCEPTION 'confirmed bootstrap must create exactly one active owner membership';
  END IF;
END;
$$;
