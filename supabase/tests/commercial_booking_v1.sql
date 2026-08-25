-- Voya OS V1 commercial booking contract checks.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('public.booking_v1_command_idempotency') IS NULL
    OR to_regprocedure('public.create_commercial_booking_draft(uuid,uuid,uuid,date,date,text,text,text,uuid)') IS NULL
    OR to_regprocedure('public.request_booking_amendment(uuid,uuid,uuid,uuid,date,date,text,text,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'commercial booking V1 contract is incomplete';
  END IF;
  IF (SELECT commercial_completion_status FROM public.bookings WHERE id = 'aaaaaaaa-0000-0000-0000-000000000003') <> 'needs_completion' THEN
    RAISE EXCEPTION 'legacy booking without a price must remain NEEDS_COMPLETION';
  END IF;
  IF has_function_privilege('authenticated', 'public.create_booking_draft(uuid,uuid,uuid,date,date,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.request_booking_approval(uuid,uuid,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.confirm_booking(uuid,uuid,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.record_booking_stay_event(uuid,uuid,text,text,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'legacy booking write RPCs must not remain executable by authenticated';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);

SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2050-01-10', DATE '2050-01-13', '2500000', 'EGP', 'commercial-v1-draft-1',
  'aaaaaaaa-0000-0000-0000-000000000501'
) AS booking_id \gset
SELECT set_config('voya.test.booking_id', :'booking_id', false);

SELECT public.request_commercial_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'commercial-v1-approval-1',
  'aaaaaaaa-0000-0000-0000-000000000502'
) AS approval_id \gset

RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'approval_id', 'approved', 'تمت مراجعة snapshot التجاري.',
  'aaaaaaaa-0000-0000-0000-000000000503'
);
SELECT public.confirm_commercial_booking(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'commercial-v1-confirm-1',
  'aaaaaaaa-0000-0000-0000-000000000504'
);
RESET ROLE;

DO $$
DECLARE
  v_booking_id uuid := current_setting('voya.test.booking_id')::uuid;
BEGIN
  IF (SELECT status FROM public.bookings WHERE id = v_booking_id) <> 'confirmed'
    OR (SELECT agreed_total_amount_minor FROM public.bookings WHERE id = v_booking_id) <> 2500000
    OR (SELECT currency FROM public.bookings WHERE id = v_booking_id) <> 'EGP' THEN
    RAISE EXCEPTION 'commercial booking did not persist its price snapshot';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
SELECT public.request_booking_amendment(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id',
  'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2050-01-10', DATE '2050-01-14', '3000000', 'EGP', 'تمديد الإقامة',
  'commercial-v1-amend-request-1', 'aaaaaaaa-0000-0000-0000-000000000505'
) AS amendment_approval_id \gset
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'amendment_approval_id', 'approved', 'تمت مراجعة التعديل.',
  'aaaaaaaa-0000-0000-0000-000000000506'
);
SELECT public.execute_booking_amendment(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'commercial-v1-amend-execute-1',
  'aaaaaaaa-0000-0000-0000-000000000507'
);
RESET ROLE;

DO $$
DECLARE
  v_booking_id uuid := current_setting('voya.test.booking_id')::uuid;
BEGIN
  IF (SELECT check_out FROM public.bookings WHERE id = v_booking_id) <> DATE '2050-01-14'
    OR (SELECT agreed_total_amount_minor FROM public.bookings WHERE id = v_booking_id) <> 3000000 THEN
    RAISE EXCEPTION 'approved amendment did not apply atomically';
  END IF;
  IF (SELECT count(*) FROM public.property_occupancies WHERE booking_id = v_booking_id) <> 1 THEN
    RAISE EXCEPTION 'amendment must keep one occupancy ledger row';
  END IF;
END;
$$;

-- A complete commercial snapshot is immutable outside the amendment workflow.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
DECLARE
  v_booking_id uuid := current_setting('voya.test.booking_id')::uuid;
BEGIN
  BEGIN
    PERFORM public.complete_booking_commercial_snapshot(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_booking_id, '3100000', 'EGP',
      'محاولة تغيير السعر بعد الاعتماد', 'commercial-v1-complete-after-confirm',
      'aaaaaaaa-0000-0000-0000-000000000509'
    );
    RAISE EXCEPTION 'already-complete commercial snapshot was mutated outside amendment approval';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
END;
$$;

-- Stay-event idempotency must bind to the original payload, not only the key.
SELECT public.record_commercial_booking_stay_event(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'check_in', 'وصول الضيف',
  'commercial-v1-stay-event-1', 'aaaaaaaa-0000-0000-0000-000000000510'
) AS check_in_event_id \gset
DO $$
DECLARE
  v_booking_id uuid := current_setting('voya.test.booking_id')::uuid;
BEGIN
  BEGIN
    PERFORM public.record_commercial_booking_stay_event(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_booking_id, 'check_out', 'مغادرة مختلفة',
      'commercial-v1-stay-event-1', 'aaaaaaaa-0000-0000-0000-000000000511'
    );
    RAISE EXCEPTION 'stay-event idempotency key accepted a different payload';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

-- Checked-in stays can be amended (including extension) but arrival identity is frozen.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
SELECT public.request_booking_amendment(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id',
  'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2050-01-10', DATE '2050-01-15', '3200000', 'EGP', 'تمديد الإقامة بعد الوصول',
  'commercial-v1-checked-in-amend-request-1', 'aaaaaaaa-0000-0000-0000-000000000512'
) AS checked_in_amendment_approval_id \gset
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'checked_in_amendment_approval_id', 'approved',
  'تمت مراجعة تمديد الإقامة بعد الوصول.', 'aaaaaaaa-0000-0000-0000-000000000513'
);
SELECT public.execute_booking_amendment(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id',
  'commercial-v1-checked-in-amend-execute-1', 'aaaaaaaa-0000-0000-0000-000000000514'
);
RESET ROLE;

DO $$
DECLARE
  v_booking_id uuid := current_setting('voya.test.booking_id')::uuid;
BEGIN
  IF (SELECT status FROM public.bookings WHERE id = v_booking_id) <> 'checked_in'
    OR (SELECT check_out FROM public.bookings WHERE id = v_booking_id) <> DATE '2050-01-15'
    OR (SELECT agreed_total_amount_minor FROM public.bookings WHERE id = v_booking_id) <> 3200000 THEN
    RAISE EXCEPTION 'checked-in amendment did not preserve stay state and apply the approved extension';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
DO $$
DECLARE
  v_booking_id uuid := current_setting('voya.test.booking_id')::uuid;
BEGIN
  BEGIN
    PERFORM public.request_booking_amendment(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_booking_id,
      'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
      DATE '2050-01-11', DATE '2050-01-16', '3300000', 'EGP', 'محاولة تغيير تاريخ الوصول بعد الوصول',
      'commercial-v1-checked-in-invalid-arrival', 'aaaaaaaa-0000-0000-0000-000000000515'
    );
    RAISE EXCEPTION 'checked-in amendment changed the frozen arrival identity';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
END;
$$;

-- Checked-in bookings can also follow the independent cancellation approval path.
SELECT public.request_booking_cancellation(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'إلغاء مبكر بعد الوصول',
  'commercial-v1-checked-in-cancel-request-1', 'aaaaaaaa-0000-0000-0000-000000000516'
) AS checked_in_cancellation_approval_id \gset
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'checked_in_cancellation_approval_id', 'approved',
  'تمت مراجعة الإلغاء بعد الوصول.', 'aaaaaaaa-0000-0000-0000-000000000517'
);
SELECT public.execute_booking_cancellation(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id',
  'commercial-v1-checked-in-cancel-execute-1', 'aaaaaaaa-0000-0000-0000-000000000518'
);
RESET ROLE;

DO $$
DECLARE
  v_booking_id uuid := current_setting('voya.test.booking_id')::uuid;
BEGIN
  IF (SELECT status FROM public.bookings WHERE id = v_booking_id) <> 'cancelled' THEN
    RAISE EXCEPTION 'approved checked-in cancellation did not execute';
  END IF;
  IF EXISTS (SELECT 1 FROM public.property_occupancies WHERE booking_id = v_booking_id) THEN
    RAISE EXCEPTION 'cancelled checked-in booking must release its occupancy row';
  END IF;
END;
$$;

-- Renewing an expired confirmation approval must leave only one actionable pending request.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2050-03-10', DATE '2050-03-13', '1800000', 'EGP', 'commercial-v1-expiry-draft-1',
  'aaaaaaaa-0000-0000-0000-000000000519'
) AS expiry_booking_id \gset
SELECT set_config('voya.test.expiry_booking_id', :'expiry_booking_id', false);
SELECT public.request_commercial_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'expiry_booking_id', 'commercial-v1-expiry-approval-1',
  'aaaaaaaa-0000-0000-0000-000000000520'
) AS expired_approval_id \gset
SELECT set_config('voya.test.expired_approval_id', :'expired_approval_id', false);
RESET ROLE;

UPDATE public.approval_requests
SET expires_at = timezone('utc', now()) - interval '1 minute'
WHERE id = :'expired_approval_id';

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
SELECT public.request_commercial_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'expiry_booking_id', 'commercial-v1-expiry-approval-2',
  'aaaaaaaa-0000-0000-0000-000000000521'
) AS renewed_approval_id \gset
RESET ROLE;

DO $$
DECLARE
  v_booking_id uuid := current_setting('voya.test.expiry_booking_id')::uuid;
  v_expired_approval_id uuid := current_setting('voya.test.expired_approval_id')::uuid;
BEGIN
  IF (SELECT count(*) FROM public.approval_requests
      WHERE resource_type = 'booking'
        AND resource_id = v_booking_id
        AND proposed_action = 'booking.confirm'
        AND status = 'pending') <> 1 THEN
    RAISE EXCEPTION 'expired booking approval renewal left multiple pending requests';
  END IF;
  IF (SELECT status FROM public.approval_requests WHERE id = v_expired_approval_id) <> 'expired' THEN
    RAISE EXCEPTION 'stale pending booking approval was not marked expired';
  END IF;
END;
$$;

INSERT INTO public.clients (id, organization_id, display_name, archived_at)
VALUES (
  'aaaaaaaa-0000-0000-0000-000000000009',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'Archived commercial client',
  timezone('utc', now())
)
ON CONFLICT (id) DO UPDATE SET archived_at = EXCLUDED.archived_at;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.create_commercial_booking_draft(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000009',
      DATE '2050-02-10', DATE '2050-02-13', '2500000', 'EGP',
      'commercial-v1-archived-client',
      'aaaaaaaa-0000-0000-0000-000000000508'
    );
    RAISE EXCEPTION 'archived client was accepted for a new booking';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'commercial booking V1 tests passed' AS result;
