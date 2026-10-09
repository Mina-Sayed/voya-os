\set ON_ERROR_STOP on

DO $$
DECLARE v_function regprocedure;
BEGIN
  SELECT procedure.oid::regprocedure INTO v_function
  FROM pg_catalog.pg_proc AS procedure
  JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
  CROSS JOIN LATERAL aclexplode(coalesce(
    procedure.proacl,
    pg_catalog.acldefault('f', procedure.proowner)
  )) AS privilege
  WHERE namespace.nspname = 'public'
    AND privilege.grantee = 0
    AND privilege.privilege_type = 'EXECUTE'
  LIMIT 1;
  IF v_function IS NOT NULL THEN
    RAISE EXCEPTION 'PUBLIC retains function execute on %', v_function;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_default_acl AS default_acl
    CROSS JOIN LATERAL aclexplode(default_acl.defaclacl) AS privilege
    WHERE default_acl.defaclrole = 'postgres'::regrole
      AND default_acl.defaclnamespace IN (0, 'public'::regnamespace)
      AND default_acl.defaclobjtype = 'f'
      AND privilege.grantee = 0
      AND privilege.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'future public-schema functions inherit PUBLIC execute';
  END IF;
END;
$$;

CREATE FUNCTION public.review_default_execute_self_test()
RETURNS integer LANGUAGE sql AS 'SELECT 1';
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS procedure
    CROSS JOIN LATERAL aclexplode(coalesce(
      procedure.proacl,
      pg_catalog.acldefault('f', procedure.proowner)
    )) AS privilege
    WHERE procedure.oid = 'public.review_default_execute_self_test()'::regprocedure
      AND privilege.grantee = 0 AND privilege.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'new public-schema function inherited PUBLIC execute';
  END IF;
END;
$$;
DROP FUNCTION public.review_default_execute_self_test();

SELECT 'PUBLIC function execute posture verified' AS result;
