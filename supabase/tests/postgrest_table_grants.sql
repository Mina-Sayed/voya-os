-- PostgREST table grants are explicit least-privilege invariants.
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_unexpected_privileges text[];
  v_missing_select text[];
BEGIN
  -- These are the only public tables intentionally exposed to authenticated
  -- reads.  All writes and maintenance remain RPC/service-owned.
  WITH allowed_authenticated_select(relation_name) AS (
    VALUES
      ('profiles'::name),
      ('organizations'::name),
      ('organization_memberships'::name),
      ('properties'::name),
      ('bookings'::name)
  )
  SELECT array_agg(allowed.relation_name::text ORDER BY allowed.relation_name)
  INTO v_missing_select
  FROM allowed_authenticated_select AS allowed
  WHERE NOT has_table_privilege(
    'authenticated',
    format('public.%I', allowed.relation_name)::regclass,
    'SELECT'
  );

  IF v_missing_select IS NOT NULL THEN
    RAISE EXCEPTION 'documented authenticated table SELECT grants are missing: %', v_missing_select;
  END IF;

  -- Check the complete meaningful table privilege set instead of only SELECT.
  -- This catches accidental browser writes on RPC-only tables and catches
  -- maintenance privileges inherited through PUBLIC or a role grant.
  WITH privilege_types(privilege_type) AS (
    SELECT privilege.privilege_type
    FROM (VALUES
      ('SELECT'::text),
      ('INSERT'::text),
      ('UPDATE'::text),
      ('DELETE'::text),
      ('TRUNCATE'::text),
      ('REFERENCES'::text),
      ('TRIGGER'::text),
      ('MAINTAIN'::text)
    ) AS privilege(privilege_type)
    -- MAINTAIN is a PostgreSQL 17+ table privilege. Older disposable
    -- servers cannot expose it; PostgreSQL 17+ runs the full matrix.
    WHERE privilege.privilege_type <> 'MAINTAIN'
      OR current_setting('server_version_num')::integer >= 170000
  ),
  public_tables AS (
    SELECT relation.oid, relation.relname
    FROM pg_class AS relation
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relkind IN ('r', 'p')
  ),
  allowed_authenticated_select(relation_name) AS (
    VALUES
      ('profiles'::name),
      ('organizations'::name),
      ('organization_memberships'::name),
      ('properties'::name),
      ('bookings'::name)
  ),
  violations AS (
    SELECT 'anon'::text AS principal, table_record.relname, privilege.privilege_type
    FROM public_tables AS table_record
    CROSS JOIN privilege_types AS privilege
    WHERE has_table_privilege('anon', table_record.oid, privilege.privilege_type)
    UNION ALL
    SELECT 'authenticated', table_record.relname, privilege.privilege_type
    FROM public_tables AS table_record
    CROSS JOIN privilege_types AS privilege
    WHERE has_table_privilege('authenticated', table_record.oid, privilege.privilege_type)
      AND NOT (
        privilege.privilege_type = 'SELECT'
        AND table_record.relname IN (SELECT relation_name FROM allowed_authenticated_select)
      )
  )
  SELECT array_agg(
    format('%s:%s:%s', violation.principal, violation.relname, violation.privilege_type)
    ORDER BY violation.principal, violation.relname, violation.privilege_type
  )
  INTO v_unexpected_privileges
  FROM violations AS violation;

  IF v_unexpected_privileges IS NOT NULL THEN
    RAISE EXCEPTION 'unexpected PostgREST table privileges: %', v_unexpected_privileges;
  END IF;

  IF has_function_privilege(
    'authenticated',
    'public.purge_auth_rate_limit_buckets(integer,integer)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated retains worker-only auth rate-limit purge access';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_extension AS extension
    JOIN pg_namespace AS namespace ON namespace.oid = extension.extnamespace
    WHERE extension.extname = 'btree_gist'
      AND namespace.nspname = 'public'
  ) THEN
    RAISE EXCEPTION 'btree_gist remains installed in the exposed public schema';
  END IF;
END;
$$;

SELECT 'PostgREST table grant integration tests passed' AS result;
