-- Voya OS: explicit money and timezone contracts.
--
-- This migration is forward-only. Existing values are not rewritten or
-- rescaled. Validation applies to new values and real changes to governed
-- fields while allowing an unchanged historical value to pass through an
-- update until an operator explicitly recovers it to the supported contract.

CREATE TABLE IF NOT EXISTS public.supported_currency_contract (
  code text PRIMARY KEY CHECK (code ~ '^[A-Z]{3}$'),
  minor_digits smallint NOT NULL CHECK (minor_digits BETWEEN 0 AND 3),
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 120)
);

INSERT INTO public.supported_currency_contract (code, minor_digits, display_name)
VALUES
  ('AED', 2, 'United Arab Emirates dirham'),
  ('BHD', 3, 'Bahraini dinar'),
  ('EGP', 2, 'Egyptian pound'),
  ('EUR', 2, 'Euro'),
  ('GBP', 2, 'Pound sterling'),
  ('IQD', 3, 'Iraqi dinar'),
  ('JOD', 3, 'Jordanian dinar'),
  ('JPY', 0, 'Japanese yen'),
  ('KWD', 3, 'Kuwaiti dinar'),
  ('LYD', 3, 'Libyan dinar'),
  ('MAD', 2, 'Moroccan dirham'),
  ('OMR', 3, 'Omani rial'),
  ('QAR', 2, 'Qatari riyal'),
  ('SAR', 2, 'Saudi riyal'),
  ('TND', 3, 'Tunisian dinar'),
  ('USD', 2, 'United States dollar')
ON CONFLICT (code) DO UPDATE
SET minor_digits = EXCLUDED.minor_digits,
    display_name = EXCLUDED.display_name;

CREATE TABLE IF NOT EXISTS public.supported_timezone_contract (
  name text PRIMARY KEY CHECK (char_length(btrim(name)) BETWEEN 1 AND 80)
);

INSERT INTO public.supported_timezone_contract (name)
VALUES
  ('UTC'),
  ('Africa/Cairo'),
  ('Africa/Casablanca'),
  ('Africa/Johannesburg'),
  ('Africa/Tripoli'),
  ('America/Chicago'),
  ('America/Los_Angeles'),
  ('America/New_York'),
  ('Asia/Amman'),
  ('Asia/Baghdad'),
  ('Asia/Beirut'),
  ('Asia/Dubai'),
  ('Asia/Kuwait'),
  ('Asia/Muscat'),
  ('Asia/Qatar'),
  ('Asia/Riyadh'),
  ('Europe/Berlin'),
  ('Europe/London'),
  ('Europe/Paris')
ON CONFLICT (name) DO NOTHING;

DO $$
DECLARE
  v_missing text;
BEGIN
  SELECT contract.name
  INTO v_missing
  FROM public.supported_timezone_contract AS contract
  LEFT JOIN pg_catalog.pg_timezone_names AS timezone_name
    ON timezone_name.name = contract.name
  WHERE timezone_name.name IS NULL
  ORDER BY contract.name
  LIMIT 1;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'timezone contract contains a name PostgreSQL cannot interpret: %', v_missing
      USING ERRCODE = '22023';
  END IF;
END;
$$;

REVOKE ALL ON TABLE public.supported_currency_contract, public.supported_timezone_contract FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.supported_currency_minor_digits(p_currency text)
RETURNS smallint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT contract.minor_digits
  FROM public.supported_currency_contract AS contract
  WHERE contract.code = p_currency;
$$;

CREATE OR REPLACE FUNCTION public.is_supported_currency(p_currency text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT public.supported_currency_minor_digits(p_currency) IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.is_supported_timezone(p_timezone text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.supported_timezone_contract AS contract
    JOIN pg_catalog.pg_timezone_names AS timezone_name ON timezone_name.name = contract.name
    WHERE contract.name = p_timezone
  );
$$;

REVOKE ALL ON FUNCTION public.supported_currency_minor_digits(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.is_supported_currency(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.is_supported_timezone(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.validate_money_contract()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_currency text;
  v_minor_digits smallint;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF TG_TABLE_NAME = 'organizations' THEN
      IF NEW.default_currency IS NOT DISTINCT FROM OLD.default_currency THEN
        RETURN NEW;
      END IF;
    ELSIF TG_TABLE_NAME = 'bookings' THEN
      IF NEW.currency IS NOT DISTINCT FROM OLD.currency THEN
        RETURN NEW;
      END IF;
    ELSIF TG_TABLE_NAME = 'properties' THEN
      IF NEW.currency IS NOT DISTINCT FROM OLD.currency
        AND NEW.daily_price IS NOT DISTINCT FROM OLD.daily_price
        AND NEW.weekly_price IS NOT DISTINCT FROM OLD.weekly_price
        AND NEW.monthly_price IS NOT DISTINCT FROM OLD.monthly_price THEN
        RETURN NEW;
      END IF;
    END IF;
  END IF;

  IF TG_TABLE_NAME = 'organizations' THEN
    v_currency := NEW.default_currency;
  ELSIF TG_TABLE_NAME = 'properties' THEN
    v_currency := NEW.currency;
  ELSIF TG_TABLE_NAME = 'bookings' THEN
    v_currency := NEW.currency;
  ELSE
    RAISE EXCEPTION 'money contract trigger is attached to an unsupported table: %', TG_TABLE_NAME
      USING ERRCODE = '55000';
  END IF;

  IF v_currency IS NULL THEN
    RETURN NEW;
  END IF;

  v_minor_digits := public.supported_currency_minor_digits(v_currency);
  IF v_minor_digits IS NULL THEN
    RAISE EXCEPTION 'currency is not supported by the current contract: %', v_currency
      USING ERRCODE = '22023';
  END IF;

  IF TG_TABLE_NAME = 'properties' THEN
    IF (NEW.daily_price IS NOT NULL AND NEW.daily_price <> round(NEW.daily_price, v_minor_digits::integer))
      OR (NEW.weekly_price IS NOT NULL AND NEW.weekly_price <> round(NEW.weekly_price, v_minor_digits::integer))
      OR (NEW.monthly_price IS NOT NULL AND NEW.monthly_price <> round(NEW.monthly_price, v_minor_digits::integer)) THEN
      RAISE EXCEPTION 'property price exceeds the supported currency precision for %', v_currency
        USING ERRCODE = '22023';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_timezone_contract()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_timezone text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.timezone IS NOT DISTINCT FROM OLD.timezone THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'organizations' OR TG_TABLE_NAME = 'properties' THEN
    v_timezone := NEW.timezone;
  END IF;

  IF NOT public.is_supported_timezone(v_timezone) THEN
    RAISE EXCEPTION 'timezone is not supported by the application/database contract: %', v_timezone
      USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_money_contract() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.validate_timezone_contract() FROM PUBLIC, anon, authenticated;

-- The previous property price columns could store only two decimal places,
-- while the explicit contract includes currencies with three. Widen the scale
-- before attaching triggers that depend on these columns. This preserves every
-- existing value and does not rescale historical data.
ALTER TABLE public.properties
  ALTER COLUMN daily_price TYPE numeric(20, 3) USING daily_price,
  ALTER COLUMN weekly_price TYPE numeric(20, 3) USING weekly_price,
  ALTER COLUMN monthly_price TYPE numeric(20, 3) USING monthly_price;

DROP TRIGGER IF EXISTS organizations_money_contract ON public.organizations;
CREATE TRIGGER organizations_money_contract
BEFORE INSERT OR UPDATE OF default_currency ON public.organizations
FOR EACH ROW EXECUTE FUNCTION public.validate_money_contract();

DROP TRIGGER IF EXISTS properties_money_contract ON public.properties;
CREATE TRIGGER properties_money_contract
BEFORE INSERT OR UPDATE OF currency, daily_price, weekly_price, monthly_price ON public.properties
FOR EACH ROW EXECUTE FUNCTION public.validate_money_contract();

DROP TRIGGER IF EXISTS bookings_money_contract ON public.bookings;
CREATE TRIGGER bookings_money_contract
BEFORE INSERT OR UPDATE OF currency ON public.bookings
FOR EACH ROW EXECUTE FUNCTION public.validate_money_contract();

DROP TRIGGER IF EXISTS organizations_timezone_contract ON public.organizations;
CREATE TRIGGER organizations_timezone_contract
BEFORE INSERT OR UPDATE OF timezone ON public.organizations
FOR EACH ROW EXECUTE FUNCTION public.validate_timezone_contract();

DROP TRIGGER IF EXISTS properties_timezone_contract ON public.properties;
CREATE TRIGGER properties_timezone_contract
BEFORE INSERT OR UPDATE OF timezone ON public.properties
FOR EACH ROW EXECUTE FUNCTION public.validate_timezone_contract();

COMMENT ON TABLE public.supported_currency_contract IS
  'Explicit Voya money contract for currency support and decimal precision. Add currencies only through a reviewed migration.';
COMMENT ON TABLE public.supported_timezone_contract IS
  'Explicit intersection of application and PostgreSQL timezone support. Existing values are not rewritten by the contract migration.';
