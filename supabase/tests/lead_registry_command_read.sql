-- Lead registry safety: operational fields only, command-owned and tenant-isolated.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.leads', 'SELECT')
    OR has_table_privilege('authenticated', 'public.leads', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must not receive direct lead reads or inserts';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_lead(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'إقامة صيفية', 'website', 'new', DATE '2027-06-01', DATE '2027-06-05',
  NULL, 'lead-command-a-1', 'aaaaaaaa-0000-0000-0000-0000000000d1'
);
SELECT public.create_lead(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'إقامة صيفية', 'website', 'new', DATE '2027-06-01', DATE '2027-06-05',
  NULL, 'lead-command-a-1', 'aaaaaaaa-0000-0000-0000-0000000000d2'
);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.list_leads('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')) <> 1 THEN
    RAISE EXCEPTION 'lead list must return the tenant lead to its owner';
  END IF;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.leads WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND idempotency_key = 'lead-command-a-1') <> 1 THEN
    RAISE EXCEPTION 'lead command did not persist exactly once';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE action = 'lead.created' AND organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') <> 1 THEN
    RAISE EXCEPTION 'lead command must append audit evidence';
  END IF;
  IF (SELECT count(*) FROM public.outbox_events WHERE event_type = 'lead.created' AND organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') <> 1 THEN
    RAISE EXCEPTION 'lead command must enqueue an outbox event';
  END IF;
END;
$$;

SELECT 'lead registry database integration tests passed' AS result;
