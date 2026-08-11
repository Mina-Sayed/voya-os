-- Keep PostgREST table access deny-by-default. RLS remains the tenant
-- boundary, but role-level table grants must not be broader than the
-- application contract.

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon;

DO $$
DECLARE
  table_record record;
BEGIN
  -- Tables with RLS but no policies are service-owned. Their RPCs and workers
  -- are the only supported access path, so authenticated must not retain the
  -- default PostgREST table grants on them.
  FOR table_record IN
    SELECT table_name
    FROM information_schema.tables AS table_info
    WHERE table_info.table_schema = 'public'
      AND table_info.table_type = 'BASE TABLE'
      AND EXISTS (
        SELECT 1
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace
          ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public'
          AND relation.relname = table_info.table_name
          AND relation.relrowsecurity
      )
      AND NOT EXISTS (
        SELECT 1
        FROM pg_policy AS policy
        JOIN pg_class AS relation
          ON relation.oid = policy.polrelid
        JOIN pg_namespace AS namespace
          ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public'
          AND relation.relname = table_info.table_name
      )
  LOOP
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM authenticated', table_record.table_name);
  END LOOP;
END;
$$;

