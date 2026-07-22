-- Client registry is command-owned and deliberately excludes contact/lead PII.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.clients', 'SELECT')
    OR has_table_privilege('authenticated', 'public.clients', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must not receive direct client reads or inserts';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_client(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'عميل النيل',
  'client-command-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000c0'
);

SELECT count(*) FROM public.list_clients('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.clients
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND idempotency_key = 'client-command-a-1') <> 1 THEN
    RAISE EXCEPTION 'authorized client command did not persist exactly one record';
  END IF;

  IF (SELECT count(*) FROM public.audit_events
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND action = 'client.created'
        AND outcome = 'success') <> 1 THEN
    RAISE EXCEPTION 'client command must append audit evidence';
  END IF;

  IF (SELECT count(*) FROM public.outbox_events
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND event_type = 'client.created') <> 1 THEN
    RAISE EXCEPTION 'client command must enqueue an outbox event';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_client(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'عميل النيل',
  'client-command-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000c1'
);
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_clients('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'suspended viewer must not read clients';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    PERFORM public.create_client(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'عميل مرفوض',
      'client-command-denied',
      'aaaaaaaa-0000-0000-0000-0000000000c2'
    );
    RAISE EXCEPTION 'suspended viewer must not create clients';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;
