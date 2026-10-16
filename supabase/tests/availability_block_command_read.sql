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
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
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

-- Edit and delete (update_availability_block_v1 / delete_availability_block_v1).
SELECT set_config('voya.test_block_id', (SELECT id::text FROM public.availability_blocks WHERE idempotency_key = 'availability-block-a-1'), false);
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
SELECT public.update_availability_block_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test_block_id')::uuid,
  DATE '2027-06-11', DATE '2027-06-16', 'owner_use', '  ', 'aaaaaaaa-0000-0000-0000-0000000000d3'
);
RESET ROLE;

DO $$
DECLARE
  v_block public.availability_blocks%ROWTYPE;
BEGIN
  SELECT * INTO v_block FROM public.availability_blocks WHERE idempotency_key = 'availability-block-a-1';
  IF v_block.start_date <> DATE '2027-06-11' OR v_block.end_date <> DATE '2027-06-16'
    OR v_block.block_type <> 'owner_use' OR v_block.reason IS NOT NULL THEN
    RAISE EXCEPTION 'availability block update did not persist the new values';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.property_occupancies
      WHERE availability_block_id = v_block.id AND start_date = DATE '2027-06-11' AND end_date = DATE '2027-06-16') THEN
    RAISE EXCEPTION 'availability block update must re-sync the occupancy ledger';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE action = 'availability_block.updated') <> 1 THEN
    RAISE EXCEPTION 'availability block update must append audit evidence';
  END IF;
END;
$$;

-- Suspended members and wrong tenants cannot edit or delete.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
DECLARE
  v_block_id uuid := 'aaaaaaaa-0000-0000-0000-00000000ffff';
BEGIN
  BEGIN
    PERFORM public.update_availability_block_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_block_id,
      DATE '2027-06-11', DATE '2027-06-12', 'maintenance', NULL, NULL);
    RAISE EXCEPTION 'suspended viewer must not update availability blocks';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.delete_availability_block_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_block_id, NULL);
    RAISE EXCEPTION 'suspended viewer must not delete availability blocks';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.delete_availability_block_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test_block_id')::uuid,
  'aaaaaaaa-0000-0000-0000-0000000000d4'
);
RESET ROLE;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.availability_blocks WHERE idempotency_key = 'availability-block-a-1') THEN
    RAISE EXCEPTION 'availability block delete did not remove the block';
  END IF;
  IF EXISTS (SELECT 1 FROM public.property_occupancies AS occupancy
      WHERE occupancy.availability_block_id IS NOT NULL
        AND occupancy.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND occupancy.start_date = DATE '2027-06-11') THEN
    RAISE EXCEPTION 'availability block delete must release the occupancy ledger';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE action = 'availability_block.deleted') <> 1 THEN
    RAISE EXCEPTION 'availability block delete must append audit evidence';
  END IF;
  IF (SELECT count(*) FROM public.outbox_events WHERE event_type = 'availability_block.deleted') <> 1 THEN
    RAISE EXCEPTION 'availability block delete must enqueue an outbox event';
  END IF;
END;
$$;
