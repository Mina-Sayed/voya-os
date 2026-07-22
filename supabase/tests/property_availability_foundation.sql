-- Run after tenancy_booking_foundation.sql and all property/availability migrations.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('public.property_owners') IS NULL THEN
    RAISE EXCEPTION 'property_owners table is required';
  END IF;
  IF to_regclass('public.property_ownership_periods') IS NULL THEN
    RAISE EXCEPTION 'property_ownership_periods table is required';
  END IF;
  IF to_regclass('public.availability_blocks') IS NULL THEN
    RAISE EXCEPTION 'availability_blocks table is required';
  END IF;
END;
$$;

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.property_owners', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must not have INSERT privilege on property_owners';
  END IF;
  IF has_table_privilege('authenticated', 'public.property_owners', 'UPDATE') THEN
    RAISE EXCEPTION 'authenticated must not have UPDATE privilege on property_owners';
  END IF;
  IF has_table_privilege('authenticated', 'public.property_owners', 'DELETE') THEN
    RAISE EXCEPTION 'authenticated must not have DELETE privilege on property_owners';
  END IF;

  IF has_table_privilege('authenticated', 'public.property_ownership_periods', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must not have INSERT privilege on property_ownership_periods';
  END IF;
  IF has_table_privilege('authenticated', 'public.property_ownership_periods', 'UPDATE') THEN
    RAISE EXCEPTION 'authenticated must not have UPDATE privilege on property_ownership_periods';
  END IF;
  IF has_table_privilege('authenticated', 'public.property_ownership_periods', 'DELETE') THEN
    RAISE EXCEPTION 'authenticated must not have DELETE privilege on property_ownership_periods';
  END IF;

  IF has_table_privilege('authenticated', 'public.availability_blocks', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must not have INSERT privilege on availability_blocks';
  END IF;
  IF has_table_privilege('authenticated', 'public.availability_blocks', 'UPDATE') THEN
    RAISE EXCEPTION 'authenticated must not have UPDATE privilege on availability_blocks';
  END IF;
  IF has_table_privilege('authenticated', 'public.availability_blocks', 'DELETE') THEN
    RAISE EXCEPTION 'authenticated must not have DELETE privilege on availability_blocks';
  END IF;
END;
$$;

INSERT INTO public.property_owners (id, organization_id, display_name)
VALUES
  ('aaaaaaaa-0000-0000-0000-000000000020', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Tenant A owner'),
  ('aaaaaaaa-0000-0000-0000-000000000023', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Tenant A second owner'),
  ('bbbbbbbb-0000-0000-0000-000000000020', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Tenant B owner');

DO $$
BEGIN
  BEGIN
    INSERT INTO public.property_owners (id, organization_id, display_name)
    VALUES ('aaaaaaaa-0000-0000-0000-000000000024', NULL, 'Null-tenant owner');
    RAISE EXCEPTION 'expected property owner without organization to fail';
  EXCEPTION WHEN not_null_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.property_ownership_periods (
      id, organization_id, property_id, property_owner_id, start_date, end_date
    )
    VALUES (
      'aaaaaaaa-0000-0000-0000-000000000025',
      NULL,
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000020',
      '2026-09-01',
      '2026-10-01'
    );
    RAISE EXCEPTION 'expected property ownership period without organization to fail';
  EXCEPTION WHEN not_null_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.availability_blocks (
      id, organization_id, property_id, start_date, end_date
    )
    VALUES (
      'aaaaaaaa-0000-0000-0000-000000000026',
      NULL,
      'aaaaaaaa-0000-0000-0000-000000000001',
      '2026-09-01',
      '2026-09-02'
    );
    RAISE EXCEPTION 'expected availability block without organization to fail';
  EXCEPTION WHEN not_null_violation THEN
    NULL;
  END;
END;
$$;

INSERT INTO public.property_ownership_periods (
  id, organization_id, property_id, property_owner_id, start_date, end_date
)
VALUES (
  'aaaaaaaa-0000-0000-0000-000000000021',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000020',
  '2026-10-01',
  '2026-11-01'
);

DO $$
BEGIN
  BEGIN
    INSERT INTO public.property_ownership_periods (
      organization_id, property_id, property_owner_id, start_date, end_date
    )
    VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000020',
      '2026-10-15',
      '2026-11-15'
    );
    RAISE EXCEPTION 'expected overlapping property ownership period to fail';
  EXCEPTION WHEN exclusion_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.property_ownership_periods (
      organization_id, property_id, property_owner_id, start_date, end_date
    )
    VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000023',
      '2026-10-15',
      '2026-11-15'
    );
    RAISE EXCEPTION 'expected overlapping property ownership period for a second owner to fail';
  EXCEPTION WHEN exclusion_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.property_ownership_periods (
      organization_id, property_id, property_owner_id, start_date, end_date
    )
    VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000020',
      '2026-11-01',
      '2026-12-01'
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'expected adjacent property ownership period to succeed: %', SQLERRM;
  END;

  BEGIN
    INSERT INTO public.property_ownership_periods (
      organization_id, property_id, property_owner_id, start_date, end_date
    )
    VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000020',
      '2026-12-01',
      '2026-12-01'
    );
    RAISE EXCEPTION 'expected invalid property ownership period to fail';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.availability_blocks (organization_id, property_id, start_date, end_date)
    VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      '2026-12-16',
      '2026-12-15'
    );
    RAISE EXCEPTION 'expected reversed availability range to fail';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.property_ownership_periods (
      organization_id, property_id, property_owner_id, start_date, end_date
    )
    VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'bbbbbbbb-0000-0000-0000-000000000020',
      '2027-01-01',
      '2027-02-01'
    );
    RAISE EXCEPTION 'expected cross-tenant property owner reference to fail';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.property_ownership_periods (
      organization_id, property_id, property_owner_id, start_date, end_date
    )
    VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'bbbbbbbb-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000020',
      '2027-01-01',
      '2027-02-01'
    );
    RAISE EXCEPTION 'expected cross-tenant property reference to fail';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;
END;
$$;

INSERT INTO public.availability_blocks (
  id, organization_id, property_id, start_date, end_date
)
VALUES (
  'aaaaaaaa-0000-0000-0000-000000000022',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  '2026-12-10',
  '2026-12-15'
);

DO $$
BEGIN
  BEGIN
    INSERT INTO public.availability_blocks (organization_id, property_id, start_date, end_date)
    VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      '2026-12-15',
      '2026-12-15'
    );
    RAISE EXCEPTION 'expected invalid availability range to fail';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.availability_blocks (organization_id, property_id, start_date, end_date)
    VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'bbbbbbbb-0000-0000-0000-000000000001',
      '2027-01-01',
      '2027-01-02'
    );
    RAISE EXCEPTION 'expected cross-tenant availability property reference to fail';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  BEGIN
    INSERT INTO public.property_owners (organization_id, display_name)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Browser write attempt');
    RAISE EXCEPTION 'authenticated browser role must not write property owners';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.property_ownership_periods (
      organization_id, property_id, property_owner_id, start_date, end_date
    )
    VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000020',
      '2027-02-01',
      '2027-03-01'
    );
    RAISE EXCEPTION 'authenticated browser role must not write property ownership periods';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.availability_blocks (organization_id, property_id, start_date, end_date)
    VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      '2027-03-01',
      '2027-03-02'
    );
    RAISE EXCEPTION 'authenticated browser role must not write availability blocks';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'property availability database integration tests passed' AS result;
