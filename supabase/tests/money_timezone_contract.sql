-- Money/timezone contract regression tests. Run after the complete migration set.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF (SELECT count(*) FROM public.supported_currency_contract) <> 16 THEN
    RAISE EXCEPTION 'unexpected supported currency contract size';
  END IF;
  IF public.supported_currency_minor_digits('EGP') <> 2
    OR public.supported_currency_minor_digits('JPY') <> 0
    OR public.supported_currency_minor_digits('KWD') <> 3
    OR public.supported_currency_minor_digits('XYZ') IS NOT NULL THEN
    RAISE EXCEPTION 'currency minor-unit contract is incorrect';
  END IF;
  IF NOT public.is_supported_timezone('Africa/Cairo')
    OR NOT public.is_supported_timezone('Asia/Riyadh')
    OR public.is_supported_timezone('America/Toronto')
    OR public.is_supported_timezone('Cairo-local') THEN
    RAISE EXCEPTION 'timezone contract is incorrect';
  END IF;
END;
$$;

DO $$
DECLARE
  v_id uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
BEGIN
  BEGIN
    INSERT INTO public.organizations (id, name, slug, default_currency)
    VALUES (v_id, 'Unsupported currency organization', 'unsupported-currency-org', 'XYZ');
    RAISE EXCEPTION 'unsupported organization currency was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.organizations (id, name, slug, timezone)
    VALUES (v_id, 'Unsupported timezone organization', 'unsupported-timezone-org', 'America/Toronto');
    RAISE EXCEPTION 'unsupported organization timezone was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;
END;
$$;

DO $$
DECLARE
  v_property_id uuid := 'cccccccc-0000-0000-0000-000000000001';
BEGIN
  BEGIN
    INSERT INTO public.properties (
      id, organization_id, code, name, timezone, currency, monthly_price
    ) VALUES (
      v_property_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'BAD-CURRENCY',
      'Unsupported currency property', 'Africa/Cairo', 'XYZ', 100
    );
    RAISE EXCEPTION 'unsupported property currency was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.properties (
      id, organization_id, code, name, timezone, currency, monthly_price
    ) VALUES (
      v_property_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'BAD-TIMEZONE',
      'Unsupported timezone property', 'America/Toronto', 'EGP', 100
    );
    RAISE EXCEPTION 'unsupported property timezone was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.properties (
      id, organization_id, code, name, timezone, currency, monthly_price
    ) VALUES (
      v_property_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'BAD-PRECISION',
      'Excess precision property', 'Africa/Cairo', 'JPY', 100.5
    );
    RAISE EXCEPTION 'property precision exceeded the currency contract';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  INSERT INTO public.properties (
    id, organization_id, code, name, timezone, currency, monthly_price
  ) VALUES (
    v_property_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'KWD-PRECISION',
    'Three decimal property', 'Africa/Cairo', 'KWD', 100.125
  );
  IF (SELECT monthly_price FROM public.properties WHERE id = v_property_id) <> 100.125 THEN
    RAISE EXCEPTION 'three-decimal property price was not preserved';
  END IF;
  DELETE FROM public.properties WHERE id = v_property_id;
END;
$$;

DO $$
DECLARE
  v_booking_id uuid := 'cccccccc-0000-0000-0000-000000000001';
BEGIN
  BEGIN
    INSERT INTO public.bookings (
      id, organization_id, property_id, client_id, status, check_in, check_out,
      agreed_total_amount_minor, currency, commercial_completion_status
    ) VALUES (
      v_booking_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000002', 'draft', DATE '2045-01-01',
      DATE '2045-01-02', 10000, 'XYZ', 'complete'
    );
    RAISE EXCEPTION 'unsupported booking currency was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;
END;
$$;

-- Simulate a legacy row created before this contract. The migration does not
-- rewrite it, and an unrelated update remains possible; recovery is explicit
-- when the governed field itself is changed.
DO $$
DECLARE
  v_id uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccd';
BEGIN
  ALTER TABLE public.organizations DISABLE TRIGGER organizations_timezone_contract;
  INSERT INTO public.organizations (id, name, slug, timezone, default_currency)
  VALUES (v_id, 'Legacy timezone organization', 'legacy-timezone-org', 'America/Toronto', 'EGP');
  ALTER TABLE public.organizations ENABLE TRIGGER organizations_timezone_contract;

  UPDATE public.organizations SET name = 'Legacy timezone organization (review)' WHERE id = v_id;
  IF (SELECT timezone FROM public.organizations WHERE id = v_id) <> 'America/Toronto' THEN
    RAISE EXCEPTION 'historical timezone was changed implicitly';
  END IF;

  BEGIN
    UPDATE public.organizations SET timezone = 'Asia/Riyadh' WHERE id = v_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'supported timezone recovery update failed: %', SQLERRM;
  END;
  DELETE FROM public.organizations WHERE id = v_id;
END;
$$;

SELECT 'money and timezone contract tests passed' AS result;
