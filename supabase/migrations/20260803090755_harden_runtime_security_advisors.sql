-- The purge command is worker-owned. A signed-in browser must not be able to
-- invoke it through PostgREST.
REVOKE EXECUTE ON FUNCTION public.purge_auth_rate_limit_buckets(integer, integer)
  FROM anon, authenticated;

-- Keep extension-owned operators and support functions out of the exposed
-- public schema. Existing exclusion constraints retain their OID references.
CREATE SCHEMA IF NOT EXISTS extensions;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_extension AS extension
    JOIN pg_namespace AS namespace ON namespace.oid = extension.extnamespace
    WHERE extension.extname = 'btree_gist'
      AND namespace.nspname = 'public'
  ) THEN
    EXECUTE 'ALTER EXTENSION btree_gist SET SCHEMA extensions';
  END IF;
END;
$$;
