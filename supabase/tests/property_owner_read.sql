-- Property-owner reads use a narrow authenticated RPC, not direct table grants.

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT count(*)
FROM public.list_property_owners('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);

DO $$
BEGIN
  BEGIN
    PERFORM public.list_property_owners('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'suspended membership must not read property owners';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

RESET ROLE;
