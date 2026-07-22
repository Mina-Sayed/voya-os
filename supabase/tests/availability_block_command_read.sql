-- Availability blocks are command-owned and must enter the shared occupancy ledger.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.availability_blocks', 'SELECT')
    OR has_table_privilege('authenticated', 'public.availability_blocks', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must not receive direct availability block reads or inserts';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_availability_block(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  DATE '2027-06-10', DATE '2027-06-14', 'maintenance', 'صيانة دورية',
  'availability-block-a-1', 'aaaaaaaa-0000-0000-0000-0000000000d0'
);
SELECT count(*) FROM public.list_availability_blocks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.availability_blocks
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND idempotency_key = 'availability-block-a-1') <> 1 THEN
    RAISE EXCEPTION 'authorized availability command did not persist one block';
  END IF;
  IF (SELECT count(*) FROM public.property_occupancies AS occupancy
      JOIN public.availability_blocks AS block ON block.id = occupancy.availability_block_id
      WHERE block.idempotency_key = 'availability-block-a-1') <> 1 THEN
    RAISE EXCEPTION 'availability command must enter the occupancy ledger';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE action = 'availability_block.created' AND outcome = 'success') <> 1 THEN
    RAISE EXCEPTION 'availability command must append audit evidence';
  END IF;
  IF (SELECT count(*) FROM public.outbox_events WHERE event_type = 'availability_block.created') <> 1 THEN
    RAISE EXCEPTION 'availability command must enqueue an outbox event';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_availability_block(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  DATE '2027-06-10', DATE '2027-06-14', 'maintenance', 'صيانة دورية',
  'availability-block-a-1', 'aaaaaaaa-0000-0000-0000-0000000000d1'
);
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_availability_blocks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'suspended viewer must not list availability blocks';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.create_availability_block(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001',
      DATE '2027-07-01', DATE '2027-07-03', 'administrative', NULL,
      'availability-block-denied', 'aaaaaaaa-0000-0000-0000-0000000000d2'
    );
    RAISE EXCEPTION 'suspended viewer must not create availability blocks';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;
