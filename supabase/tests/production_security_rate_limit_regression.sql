-- Proves that the managed-only password-signup migration is represented in
-- the disposable upgrade path. The call is rollback-contained and never
-- persists a bucket row.
\set ON_ERROR_STOP on

BEGIN;
SET LOCAL ROLE anon;

DO $$
DECLARE
  v_seen_regression boolean := false;
BEGIN
  BEGIN
    PERFORM public.consume_auth_rate_limit('magic_link', repeat('9', 64), 1000, 1);
  EXCEPTION WHEN SQLSTATE '42P10' THEN
    v_seen_regression := true;
  END;

  IF NOT v_seen_regression THEN
    RAISE EXCEPTION 'managed password-signup migration regression was not reproduced';
  END IF;
END;
$$;

ROLLBACK;

SELECT 'managed password-signup rate-limit regression reproduced' AS result;
