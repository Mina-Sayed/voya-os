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

-- The update enqueued availability_block.updated. That event type has no
-- delivery route, so it must be registered in the delivery capability registry
-- and rewritten to 'recorded' at insert. Left unregistered it would sit at
-- 'pending' forever (the claim function only leases registered deliverable
-- types and purge_outbox_events never deletes pending rows), which also shows
-- up as false actionable backlog in /api/health/outbox.
DO $$
DECLARE
  v_block_id uuid := current_setting('voya.test_block_id')::uuid;
  v_state text;
  v_deliverable boolean;
BEGIN
  SELECT event.state INTO v_state
  FROM public.outbox_events AS event
  WHERE event.event_type = 'availability_block.updated'
    AND event.payload ->> 'availability_block_id' = v_block_id::text;
  IF v_state IS NULL THEN
    RAISE EXCEPTION 'availability block update must enqueue an outbox event';
  END IF;
  IF v_state <> 'recorded' THEN
    RAISE EXCEPTION 'availability_block.updated must be recorded, not %', v_state;
  END IF;
  SELECT capability.deliverable INTO v_deliverable
  FROM public.outbox_event_delivery_capability AS capability
  WHERE capability.event_type = 'availability_block.updated';
  IF v_deliverable IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'availability_block.updated must be registered deliverable = false';
  END IF;
END;
$$;

-- Suspended membership of organization A cannot edit or delete, even with the
-- real block id: the membership predicate fails on status.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
DECLARE
  v_block_id uuid := current_setting('voya.test_block_id')::uuid;
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

-- Real cross-tenant denial: an active owner of organization B passes the AAL2
-- gate and the role/status branches, and is stopped only by the tenant-scoped
-- membership lookup. The block id is organization A's real block.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
DECLARE
  v_block_id uuid := current_setting('voya.test_block_id')::uuid;
BEGIN
  BEGIN
    PERFORM public.update_availability_block_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_block_id,
      DATE '2027-06-11', DATE '2027-06-12', 'maintenance', NULL, NULL);
    RAISE EXCEPTION 'a second-tenant member must not update organization A availability blocks';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.delete_availability_block_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_block_id, NULL);
    RAISE EXCEPTION 'a second-tenant member must not delete organization A availability blocks';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

-- AAL1 denial: the same active owner of organization A and the same real block
-- id, with the assurance level the browser would hold before TOTP verification.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal1', false);
DO $$
DECLARE
  v_block_id uuid := current_setting('voya.test_block_id')::uuid;
BEGIN
  BEGIN
    PERFORM public.update_availability_block_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_block_id,
      DATE '2027-06-11', DATE '2027-06-12', 'maintenance', NULL, NULL);
    RAISE EXCEPTION 'an AAL1 session must not update availability blocks';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.delete_availability_block_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_block_id, NULL);
    RAISE EXCEPTION 'an AAL1 session must not delete availability blocks';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;
-- Restore the workspace assurance level for the remaining blocks.
SELECT set_config('request.jwt.claim.aal', 'aal2', false);

-- Moving a block onto a confirmed booking's range must be rejected by the
-- shared occupancy ledger (property_occupancy_no_overlap, 23P01), not only by
-- an application check. The confirmed booking is created and removed here so
-- this file also proves the invariant when run standalone.
INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out,
  idempotency_key, agreed_total_amount_minor, currency, commercial_completion_status
) VALUES (
  'aaaaaaaa-0000-0000-0000-00000000b001',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  'confirmed', DATE '2027-09-10', DATE '2027-09-14',
  'availability-block-overlap-fixture', 100000, 'EGP', 'complete'
) ON CONFLICT (id) DO NOTHING;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
DECLARE
  v_block_id uuid := current_setting('voya.test_block_id')::uuid;
BEGIN
  BEGIN
    PERFORM public.update_availability_block_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_block_id,
      DATE '2027-09-11', DATE '2027-09-13', 'maintenance', NULL, NULL);
    RAISE EXCEPTION 'an edit onto a confirmed booking range must fail on the occupancy ledger';
  EXCEPTION WHEN exclusion_violation THEN NULL;
  END;
END;
$$;
RESET ROLE;

DO $$
DECLARE
  v_block_id uuid := current_setting('voya.test_block_id')::uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.availability_blocks
    WHERE id = v_block_id AND start_date = DATE '2027-06-11' AND end_date = DATE '2027-06-16'
  ) THEN
    RAISE EXCEPTION 'a rejected occupancy-conflicting edit must not change the block';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.property_occupancies
    WHERE availability_block_id = v_block_id
      AND start_date = DATE '2027-06-11' AND end_date = DATE '2027-06-16'
  ) THEN
    RAISE EXCEPTION 'a rejected occupancy-conflicting edit must leave the occupancy ledger unchanged';
  END IF;
  IF EXISTS (SELECT 1 FROM public.outbox_events
      WHERE event_type = 'availability_block.updated'
        AND payload ->> 'availability_block_id' = v_block_id::text
        AND state <> 'recorded') THEN
    RAISE EXCEPTION 'rejected edits must not enqueue a pending outbox event';
  END IF;
END;
$$;

DELETE FROM public.bookings WHERE id = 'aaaaaaaa-0000-0000-0000-00000000b001';

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
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
  IF NOT EXISTS (
    SELECT 1 FROM public.outbox_events
    WHERE event_type = 'availability_block.deleted' AND state = 'recorded'
  ) THEN
    RAISE EXCEPTION 'availability_block.deleted must be recorded, not left pending';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.outbox_event_delivery_capability
    WHERE event_type = 'availability_block.deleted' AND NOT deliverable
  ) THEN
    RAISE EXCEPTION 'availability_block.deleted must be registered deliverable = false';
  END IF;
END;
$$;
