-- Approval queue reads are redacted and requester-scoped for non-admin roles.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.approval_requests', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated must not receive direct approval reads';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT count(*) FROM public.list_approval_requests('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 25);
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '44444444-4444-4444-4444-444444444444', false);
SELECT count(*) FROM public.list_approval_requests('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 25);
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_approval_requests('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 25);
    RAISE EXCEPTION 'suspended viewer must not read approval requests';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;
