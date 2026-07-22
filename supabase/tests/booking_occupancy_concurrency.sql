-- The migration must make cross-table occupancy conflicts impossible even for
-- privileged writers that bypass the application command layer.

DO $$
BEGIN
  IF to_regclass('public.property_occupancies') IS NULL THEN
    RAISE EXCEPTION 'property_occupancies table is required';
  END IF;
  IF has_table_privilege('authenticated', 'public.property_occupancies', 'SELECT')
    OR has_table_privilege('authenticated', 'public.property_occupancies', 'INSERT')
    OR has_table_privilege('authenticated', 'public.property_occupancies', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.property_occupancies', 'DELETE') THEN
    RAISE EXCEPTION 'authenticated must not have access to the occupancy ledger';
  END IF;
END;
$$;

DO $$
DECLARE
  test_org uuid;
  test_property uuid;
  test_client uuid;
BEGIN
  SELECT id INTO test_org FROM public.organizations WHERE slug = 'tenant-a';
  SELECT id INTO test_property
  FROM public.properties
  WHERE organization_id = test_org AND code = 'A-101';
  SELECT id INTO test_client
  FROM public.clients
  WHERE organization_id = test_org
  LIMIT 1;

  INSERT INTO public.availability_blocks (
    organization_id, property_id, start_date, end_date, block_type
  ) VALUES (
    test_org, test_property, DATE '2027-01-10', DATE '2027-01-15', 'maintenance'
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.property_occupancies
    WHERE organization_id = test_org
      AND property_id = test_property
      AND availability_block_id IS NOT NULL
      AND start_date = DATE '2027-01-10'
      AND end_date = DATE '2027-01-15'
  ) THEN
    RAISE EXCEPTION 'availability block must create an occupancy ledger row';
  END IF;

  BEGIN
    INSERT INTO public.bookings (
      organization_id, property_id, client_id, status, check_in, check_out
    ) VALUES (
      test_org, test_property, test_client, 'confirmed', DATE '2027-01-12', DATE '2027-01-14'
    );
    RAISE EXCEPTION 'confirmed booking overlapping an availability block was accepted';
  EXCEPTION WHEN exclusion_violation THEN
    NULL;
  END;

  INSERT INTO public.bookings (
    organization_id, property_id, client_id, status, check_in, check_out
  ) VALUES (
    test_org, test_property, test_client, 'confirmed', DATE '2027-02-10', DATE '2027-02-15'
  );

  BEGIN
    INSERT INTO public.availability_blocks (
      organization_id, property_id, start_date, end_date, block_type
    ) VALUES (
      test_org, test_property, DATE '2027-02-12', DATE '2027-02-14', 'owner_use'
    );
    RAISE EXCEPTION 'availability block overlapping a confirmed booking was accepted';
  EXCEPTION WHEN exclusion_violation THEN
    NULL;
  END;

  INSERT INTO public.availability_blocks (
    organization_id, property_id, start_date, end_date, block_type
  ) VALUES (
    test_org, test_property, DATE '2027-02-15', DATE '2027-02-17', 'administrative'
  );
END;
$$;
