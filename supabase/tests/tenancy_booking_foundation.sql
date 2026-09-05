-- Run after bootstrap_auth.sql and the tenancy/booking migration.
\set ON_ERROR_STOP on

INSERT INTO auth.users (id)
VALUES
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333')
ON CONFLICT DO NOTHING;

INSERT INTO public.profiles (id, display_name)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'Tenant A user'),
  ('22222222-2222-2222-2222-222222222222', 'Tenant B user'),
  ('33333333-3333-3333-3333-333333333333', 'Inactive user')
ON CONFLICT DO NOTHING;

INSERT INTO public.organizations (id, name, slug)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Tenant A', 'tenant-a'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Tenant B', 'tenant-b')
ON CONFLICT DO NOTHING;

INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'owner', 'active'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '22222222-2222-2222-2222-222222222222', 'owner', 'active'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '33333333-3333-3333-3333-333333333333', 'viewer', 'suspended')
ON CONFLICT DO NOTHING;

INSERT INTO public.properties (id, organization_id, code, name, timezone)
VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A-101', 'A Apartment', 'Africa/Cairo'),
  ('bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B-101', 'B Apartment', 'Asia/Dubai')
ON CONFLICT DO NOTHING;

INSERT INTO public.clients (id, organization_id, display_name)
VALUES
  ('aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A Client'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B Client')
ON CONFLICT DO NOTHING;

-- Operational seed rows must satisfy the commercial-completion trigger once
-- the commercial columns exist (clean install), while the early upgrade-path
-- phase runs before those columns are added. Branch explicitly.
-- Booking ...003 doubles as the legacy NEEDS_COMPLETION witness for the
-- commercial suite, so after a complete INSERT it is grandfathered back to
-- incomplete without a status transition (which the trigger permits).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'bookings'
      AND column_name = 'agreed_total_amount_minor'
  ) THEN
    INSERT INTO public.bookings (id, organization_id, property_id, client_id, status, check_in, check_out, idempotency_key, agreed_total_amount_minor, currency, commercial_completion_status)
    VALUES
      ('aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', 'confirmed', '2026-08-10', '2026-08-13', 'confirmed-a-1', 100000, 'EGP', 'complete');
    UPDATE public.bookings
    SET agreed_total_amount_minor = NULL, currency = NULL,
        commercial_completion_status = 'needs_completion'
    WHERE id = 'aaaaaaaa-0000-0000-0000-000000000003';
  ELSE
    INSERT INTO public.bookings (id, organization_id, property_id, client_id, status, check_in, check_out, idempotency_key)
    VALUES
      ('aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', 'confirmed', '2026-08-10', '2026-08-13', 'confirmed-a-1');
  END IF;
END;
$$;

DO $$
DECLARE
  v_has_commercial boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'bookings'
      AND column_name = 'agreed_total_amount_minor'
  ) INTO v_has_commercial;
  BEGIN
    -- Commercial data keeps the overlap probe focused on the exclusion
    -- constraint once the commercial trigger exists (see above).
    IF v_has_commercial THEN
      INSERT INTO public.bookings (organization_id, property_id, client_id, status, check_in, check_out, agreed_total_amount_minor, currency, commercial_completion_status)
      VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', 'confirmed', '2026-08-12', '2026-08-15', 100000, 'EGP', 'complete');
    ELSE
      INSERT INTO public.bookings (organization_id, property_id, client_id, status, check_in, check_out)
      VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', 'confirmed', '2026-08-12', '2026-08-15');
    END IF;
    RAISE EXCEPTION 'expected overlapping confirmed booking to fail';
  EXCEPTION WHEN exclusion_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.bookings (organization_id, property_id, client_id, status, check_in, check_out)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', 'draft', '2026-08-11', '2026-08-12');
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'draft booking should be allowed to overlap: %', SQLERRM;
  END;

  BEGIN
    INSERT INTO public.bookings (organization_id, property_id, client_id, status, check_in, check_out)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002', 'draft', '2026-08-15', '2026-08-16');
    RAISE EXCEPTION 'expected cross-tenant client reference to fail';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.bookings (organization_id, property_id, client_id, status, check_in, check_out)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', 'draft', '2026-08-16', '2026-08-16');
    RAISE EXCEPTION 'expected invalid stay to fail';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'bookings'
      AND column_name = 'agreed_total_amount_minor'
  ) THEN
    INSERT INTO public.bookings (organization_id, property_id, client_id, status, check_in, check_out, idempotency_key, agreed_total_amount_minor, currency, commercial_completion_status)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', 'confirmed', '2026-08-13', '2026-08-15', 'confirmed-a-2', 100000, 'EGP', 'complete');
  ELSE
    INSERT INTO public.bookings (organization_id, property_id, client_id, status, check_in, check_out, idempotency_key)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', 'confirmed', '2026-08-13', '2026-08-15', 'confirmed-a-2');
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  IF (SELECT count(*) FROM public.properties) <> 1 THEN
    RAISE EXCEPTION 'active user must see exactly one tenant property';
  END IF;
  IF (SELECT count(*) FROM public.bookings) <> 3 THEN
    RAISE EXCEPTION 'active user must see only tenant A bookings';
  END IF;
  BEGIN
    INSERT INTO public.bookings (organization_id, property_id, client_id, status, check_in, check_out)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', 'draft', '2026-09-01', '2026-09-02');
    RAISE EXCEPTION 'authenticated browser role must not write bookings';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  IF (SELECT count(*) FROM public.properties) <> 0 THEN
    RAISE EXCEPTION 'suspended user must see no tenant data';
  END IF;
END;
$$;
RESET ROLE;

SELECT 'tenancy and booking database integration tests passed' AS result;
