DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.properties', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must not receive direct property inserts';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);

SELECT public.create_property(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'A-202',
  'شقة النيل',
  'Africa/Cairo',
  'property-command-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000b0'
);

RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.properties
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND idempotency_key = 'property-command-a-1'
        AND status = 'active') <> 1 THEN
    RAISE EXCEPTION 'authorized property command did not persist an active property';
  END IF;
END;
$$;
