-- Booking cancellation replay-guard contract (K-043 hardening).
-- Same (organization, command, key) + same payload replays the stored result
-- without duplicating approvals, audit evidence, or outbox events; the same
-- key with different data raises 23505. Expired approvals surface as 22023.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regprocedure('public.cancel_booking_draft(uuid,uuid,text,text,uuid)') IS NULL
    OR to_regprocedure('public.request_booking_cancellation(uuid,uuid,text,text,uuid)') IS NULL
    OR to_regprocedure('public.execute_booking_cancellation(uuid,uuid,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'booking cancellation commands are missing';
  END IF;
  IF has_function_privilege('anon', 'public.cancel_booking_draft(uuid,uuid,text,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.request_booking_cancellation(uuid,uuid,text,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.execute_booking_cancellation(uuid,uuid,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute booking cancellation commands';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.cancel_booking_draft(uuid,uuid,text,text,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.request_booking_cancellation(uuid,uuid,text,text,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.execute_booking_cancellation(uuid,uuid,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must retain the booking cancellation commands';
  END IF;
END;
$$;

-- Draft cancellation replays the stored success without duplicate audit.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);

SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2050-02-10', DATE '2050-02-13', '1000000', 'EGP', 'cancel-replay-draft-1',
  'aaaaaaaa-0000-0000-0000-000000000631'
) AS booking_id \gset
SELECT set_config('voya.test.cancel_draft_booking', :'booking_id', false);

SELECT public.cancel_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'طلب العميل',
  'cancel-replay-draft-key-1', 'aaaaaaaa-0000-0000-0000-000000000632'
) AS draft_cancelled \gset
SELECT public.cancel_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'طلب العميل',
  'cancel-replay-draft-key-1', 'aaaaaaaa-0000-0000-0000-000000000633'
) AS draft_cancel_replay \gset
SELECT CASE WHEN :'draft_cancel_replay'::boolean AND :'draft_cancelled'::boolean
  THEN 'draft cancellation replayed' ELSE (1 / 0)::text END AS draft_replay_check;

SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2050-02-10', DATE '2050-02-13', '1000000', 'EGP', 'cancel-replay-draft-2',
  'aaaaaaaa-0000-0000-0000-000000000634'
) AS other_booking_id \gset
SELECT set_config('voya.test.cancel_other_booking', :'other_booking_id', false);

DO $$
BEGIN
  BEGIN
    PERFORM public.cancel_booking_draft(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.cancel_other_booking')::uuid, 'سبب مختلف',
      'cancel-replay-draft-key-1', 'aaaaaaaa-0000-0000-0000-000000000635'
    );
    RAISE EXCEPTION 'draft cancellation key reuse with a different booking was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
END;
$$;

RESET ROLE;
DO $$
DECLARE
  v_booking uuid := current_setting('voya.test.cancel_draft_booking')::uuid;
BEGIN
  IF (SELECT status FROM public.bookings WHERE id = v_booking) <> 'cancelled' THEN
    RAISE EXCEPTION 'draft booking was not cancelled';
  END IF;
  IF (SELECT count(*) FROM public.audit_events
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND action = 'booking.draft_cancelled'
        AND resource_id = v_booking) <> 1 THEN
    RAISE EXCEPTION 'draft cancellation replay must not duplicate audit evidence';
  END IF;
END;
$$;

-- Cancellation requests replay the stored approval instead of opening another.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);

SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2050-03-10', DATE '2050-03-13', '2000000', 'EGP', 'cancel-replay-draft-3',
  'aaaaaaaa-0000-0000-0000-000000000636'
) AS booking_id \gset
SELECT set_config('voya.test.cancel_booking', :'booking_id', false);
SELECT public.request_commercial_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'cancel-replay-approval-1',
  'aaaaaaaa-0000-0000-0000-000000000637'
);

RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  (SELECT id FROM public.approval_requests
   WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     AND resource_id = current_setting('voya.test.cancel_booking')::uuid
     AND proposed_action = 'booking.confirm'
     AND status = 'pending'
   ORDER BY created_at DESC LIMIT 1),
  'approved', 'مراجعة معتمدة.',
  'aaaaaaaa-0000-0000-0000-000000000638'
);
SELECT public.confirm_commercial_booking(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.cancel_booking')::uuid,
  'cancel-replay-confirm-1', 'aaaaaaaa-0000-0000-0000-000000000639'
);
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
SELECT public.request_booking_cancellation(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.cancel_booking')::uuid,
  'تعذر السفر', 'cancel-replay-request-key-1', 'aaaaaaaa-0000-0000-0000-000000000640'
) AS approval_id \gset
SELECT set_config('voya.test.cancel_approval', :'approval_id', false);
SELECT public.request_booking_cancellation(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.cancel_booking')::uuid,
  'تعذر السفر', 'cancel-replay-request-key-1', 'aaaaaaaa-0000-0000-0000-000000000641'
) AS approval_replay_id \gset
SELECT CASE WHEN :'approval_replay_id'::uuid = :'approval_id'::uuid
  THEN 'cancellation request replayed' ELSE (1 / 0)::text END AS request_replay_check;

DO $$
BEGIN
  BEGIN
    PERFORM public.request_booking_cancellation(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.cancel_booking')::uuid,
      'سبب مختلف تماما', 'cancel-replay-request-key-1', 'aaaaaaaa-0000-0000-0000-000000000642'
    );
    RAISE EXCEPTION 'cancellation request key reuse with a different reason was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

DO $$
DECLARE
  v_booking uuid := current_setting('voya.test.cancel_booking')::uuid;
BEGIN
  IF (SELECT count(*) FROM public.approval_requests
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND resource_id = v_booking
        AND proposed_action = 'booking.cancel') <> 1 THEN
    RAISE EXCEPTION 'cancellation request replay must not open a duplicate approval';
  END IF;
  IF (SELECT count(*) FROM public.outbox_events
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND event_type = 'booking.cancellation.requested'
        AND payload->>'approval_request_id' = current_setting('voya.test.cancel_approval')) <> 1 THEN
    RAISE EXCEPTION 'cancellation request replay must not duplicate outbox events';
  END IF;
END;
$$;

-- Approved cancellations execute once; replays report success and expiry is invalid.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.cancel_approval')::uuid,
  'approved', 'مراجعة إلغاء معتمدة.',
  'aaaaaaaa-0000-0000-0000-000000000643'
);
SELECT public.execute_booking_cancellation(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.cancel_booking')::uuid,
  'cancel-replay-execute-key-1', 'aaaaaaaa-0000-0000-0000-000000000644'
) AS executed \gset
SELECT public.execute_booking_cancellation(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.cancel_booking')::uuid,
  'cancel-replay-execute-key-1', 'aaaaaaaa-0000-0000-0000-000000000645'
) AS executed_replay \gset
SELECT CASE WHEN :'executed_replay'::boolean AND :'executed'::boolean
  THEN 'cancellation execution replayed' ELSE (1 / 0)::text END AS execute_replay_check;
RESET ROLE;

DO $$
DECLARE
  v_booking uuid := current_setting('voya.test.cancel_booking')::uuid;
BEGIN
  IF (SELECT status FROM public.bookings WHERE id = v_booking) <> 'cancelled' THEN
    RAISE EXCEPTION 'booking was not cancelled by the approved execution';
  END IF;
  IF (SELECT status FROM public.approval_requests WHERE id = current_setting('voya.test.cancel_approval')::uuid) <> 'executed' THEN
    RAISE EXCEPTION 'cancellation approval was not marked executed';
  END IF;
  IF (SELECT count(*) FROM public.audit_events
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND action = 'booking.cancelled'
        AND resource_id = v_booking) <> 1 THEN
    RAISE EXCEPTION 'cancellation execution replay must not duplicate audit evidence';
  END IF;
END;
$$;

-- A second confirmed booking proves expired approvals fail as invalid state.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2050-04-10', DATE '2050-04-13', '3000000', 'EGP', 'cancel-replay-draft-4',
  'aaaaaaaa-0000-0000-0000-000000000646'
) AS booking_id \gset
SELECT set_config('voya.test.cancel_booking_2', :'booking_id', false);
SELECT public.request_commercial_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'cancel-replay-approval-2',
  'aaaaaaaa-0000-0000-0000-000000000647'
);
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  (SELECT id FROM public.approval_requests
   WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     AND resource_id = current_setting('voya.test.cancel_booking_2')::uuid
     AND proposed_action = 'booking.confirm'
     AND status = 'pending'
   ORDER BY created_at DESC LIMIT 1),
  'approved', 'مراجعة معتمدة.',
  'aaaaaaaa-0000-0000-0000-000000000648'
);
SELECT public.confirm_commercial_booking(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.cancel_booking_2')::uuid,
  'cancel-replay-confirm-2', 'aaaaaaaa-0000-0000-0000-000000000649'
);
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
SELECT public.request_booking_cancellation(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.cancel_booking_2')::uuid,
  'تغيير الخطط', 'cancel-replay-request-key-2', 'aaaaaaaa-0000-0000-0000-000000000650'
) AS approval_id \gset
SELECT set_config('voya.test.cancel_approval_2', :'approval_id', false);
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.cancel_approval_2')::uuid,
  'approved', 'مراجعة إلغاء معتمدة.',
  'aaaaaaaa-0000-0000-0000-000000000651'
);
RESET ROLE;

UPDATE public.approval_requests
SET expires_at = clock_timestamp() - make_interval(secs => 1)
WHERE id = current_setting('voya.test.cancel_approval_2')::uuid;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.execute_booking_cancellation(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.cancel_booking_2')::uuid,
      'cancel-replay-execute-key-2', 'aaaaaaaa-0000-0000-0000-000000000652'
    );
    RAISE EXCEPTION 'expired cancellation approval was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'booking cancellation replay-guard tests passed' AS result;
