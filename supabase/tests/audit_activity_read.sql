-- Audit readers get a redacted, role-scoped projection only.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.audit_events', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated must not receive direct audit reads';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT count(*) FROM public.list_audit_activity('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 25);
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '44444444-4444-4444-4444-444444444444', false);
DO $$
BEGIN
  IF (SELECT count(*) FROM public.list_audit_activity('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 25)
      WHERE action = 'booking.commercial_draft_created') <> 1 THEN
    RAISE EXCEPTION 'sales agent must see their own audit activity';
  END IF;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_audit_activity('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 25);
    RAISE EXCEPTION 'suspended viewer must not read audit activity';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;
