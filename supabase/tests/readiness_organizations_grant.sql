-- The production readiness probe performs only organizations.id SELECT using
-- service_role; this role must not acquire mutation grants as a side effect.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT has_table_privilege('service_role', 'public.organizations', 'SELECT') THEN
    RAISE EXCEPTION 'service_role cannot run the production readiness organizations SELECT';
  END IF;
  IF has_table_privilege('service_role', 'public.organizations', 'INSERT')
    OR has_table_privilege('service_role', 'public.organizations', 'UPDATE')
    OR has_table_privilege('service_role', 'public.organizations', 'DELETE') THEN
    RAISE EXCEPTION 'readiness grant unexpectedly allows organization mutation';
  END IF;
END;
$$;

SELECT 'Service-role readiness organization grant test passed' AS result;
