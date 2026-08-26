-- PR #10 final amendment-execution idempotency regressions.
\set ON_ERROR_STOP on

SELECT idempotency.booking_id AS replay_booking_id,
       idempotency.result_id AS replay_approval_id
FROM public.booking_v1_command_idempotency AS idempotency
WHERE idempotency.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND idempotency.command_name = 'booking.amend.execute'
  AND idempotency.idempotency_key = 'commercial-v1-amend-execute-1'
\gset

SELECT request.id AS different_approval_id
FROM public.approval_requests AS request
WHERE request.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND request.resource_type = 'booking'
  AND request.resource_id = :'replay_booking_id'::uuid
  AND request.proposed_action = 'booking.amend'
  AND request.id <> :'replay_approval_id'::uuid
ORDER BY request.created_at DESC, request.id DESC
LIMIT 1
\gset

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

-- The first execution already committed during commercial_booking_v1.sql. A
-- lost-response retry must return success even though the approval is now
-- executed and the booking version has advanced.
SELECT public.execute_booking_amendment(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'replay_booking_id'::uuid,
  :'replay_approval_id'::uuid,
  'commercial-v1-amend-execute-1',
  'aaaaaaaa-0000-0000-0000-000000000590'
);

-- Reusing the same key for another approval must fail with an integrity-style
-- idempotency conflict instead of falling through to mutable approval status.
\set ON_ERROR_STOP off
SELECT public.execute_booking_amendment(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'replay_booking_id'::uuid,
  :'different_approval_id'::uuid,
  'commercial-v1-amend-execute-1',
  'aaaaaaaa-0000-0000-0000-000000000591'
);
\set mismatch_sqlstate :SQLSTATE
\set ON_ERROR_STOP on

SELECT :'mismatch_sqlstate' = '23505' AS mismatch_rejected \gset
\if :mismatch_rejected
\else
  \echo 'Expected amendment execution idempotency reuse to fail with SQLSTATE 23505; received' :'mismatch_sqlstate'
  \quit 1
\endif

RESET ROLE;

DO $$
DECLARE
  v_booking_id uuid;
  v_approval_id uuid;
  v_audit_count integer;
  v_outbox_count integer;
BEGIN
  SELECT idempotency.booking_id, idempotency.result_id
    INTO v_booking_id, v_approval_id
  FROM public.booking_v1_command_idempotency AS idempotency
  WHERE idempotency.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND idempotency.command_name = 'booking.amend.execute'
    AND idempotency.idempotency_key = 'commercial-v1-amend-execute-1';

  IF v_booking_id IS NULL OR v_approval_id IS NULL THEN
    RAISE EXCEPTION 'amendment execution idempotency row is not bound to its approval';
  END IF;

  SELECT count(*) INTO v_audit_count
  FROM public.audit_events AS event
  WHERE event.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND event.action = 'booking.amended'
    AND event.resource_id = v_booking_id
    AND event.after_delta->>'approval_request_id' = v_approval_id::text;

  SELECT count(*) INTO v_outbox_count
  FROM public.outbox_events AS event
  WHERE event.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND event.event_type = 'booking.amended'
    AND event.payload->>'booking_id' = v_booking_id::text
    AND event.payload->>'approval_request_id' = v_approval_id::text;

  IF v_audit_count <> 1 OR v_outbox_count <> 1 THEN
    RAISE EXCEPTION 'amendment replay duplicated side effects: audit %, outbox %', v_audit_count, v_outbox_count;
  END IF;
END;
$$;

SELECT 'PR #10 amendment execution replay regressions passed' AS result;
