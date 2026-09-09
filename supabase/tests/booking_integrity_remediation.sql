-- Focused regressions for the forward booking integrity remediation.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF pg_get_functiondef('public.enforce_booking_commercial_confirmation_v1()'::regprocedure)
       NOT LIKE '%checked_out%' THEN
    RAISE EXCEPTION 'commercial booking trigger must cover checked_out';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.booking_stay_events'::regclass
      AND tgname = 'booking_stay_events_require_commercial_snapshot'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'booking stay-event commercial trigger is missing';
  END IF;
END;
$$;

INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out,
  agreed_total_amount_minor, currency, commercial_completion_status
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000401',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  'draft', DATE '2091-01-01', DATE '2091-01-02', 100000, 'EGP', 'complete'
);

-- Missing assurance claims must be rejected before legacy booking work.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
SELECT set_config('request.jwt.claims', '{"sub":"55555555-5555-5555-5555-555555555555"}', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.request_booking_approval(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000401',
      'booking-integrity-missing-aal', NULL
    );
    RAISE EXCEPTION 'missing AAL claim was accepted by request_booking_approval';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE '%MFA AAL2 is required%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.confirm_booking(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000401',
      'booking-integrity-missing-aal-confirm', NULL
    );
    RAISE EXCEPTION 'missing AAL claim was accepted by confirm_booking';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE '%MFA AAL2 is required%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.complete_booking_commercial_snapshot(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000401', '110000', 'EGP',
      'missing AAL must deny completion', 'booking-integrity-missing-aal-complete', NULL
    );
    RAISE EXCEPTION 'missing AAL claim was accepted by complete_booking_commercial_snapshot';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE '%MFA AAL2 is required%' THEN RAISE; END IF;
  END;
END;
$$;
SELECT set_config('request.jwt.claims', '{"sub":"55555555-5555-5555-5555-555555555555","aal":"aal1"}', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.request_booking_approval(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000401',
      'booking-integrity-aal1', NULL
    );
    RAISE EXCEPTION 'AAL1 claim was accepted by request_booking_approval';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE '%MFA AAL2 is required%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.complete_booking_commercial_snapshot(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000401', '110000', 'EGP',
      'AAL1 must deny completion', 'booking-integrity-aal1-complete', NULL
    );
    RAISE EXCEPTION 'AAL1 claim was accepted by complete_booking_commercial_snapshot';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE '%MFA AAL2 is required%' THEN RAISE; END IF;
  END;
END;
$$;
SELECT set_config('request.jwt.claims', '', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
SELECT public.complete_booking_commercial_snapshot(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000401', '110000', 'EGP',
  'AAL2 completion succeeds', 'booking-integrity-aal2-complete', NULL
);
RESET ROLE;

DO $$
BEGIN
  IF (SELECT agreed_total_amount_minor FROM public.bookings
      WHERE id = 'aaaaaaaa-0000-0000-0000-000000000401') <> 110000
    OR (SELECT commercial_completion_status FROM public.bookings
        WHERE id = 'aaaaaaaa-0000-0000-0000-000000000401') <> 'complete' THEN
    RAISE EXCEPTION 'AAL2 completion did not persist the commercial snapshot';
  END IF;
END;
$$;

-- Every operational status is protected on direct INSERT and on UPDATE.
DO $$
DECLARE
  v_status text;
  v_index integer := 0;
BEGIN
  FOREACH v_status IN ARRAY ARRAY['confirmed', 'checked_in', 'checked_out', 'completed'] LOOP
    v_index := v_index + 1;
    BEGIN
      INSERT INTO public.bookings (
        id, organization_id, property_id, client_id, status, check_in, check_out
      ) VALUES (
        ('aaaaaaaa-0000-0000-0000-00000000040' || v_index)::uuid,
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'aaaaaaaa-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000002',
        v_status, DATE '2091-02-01' + v_index, DATE '2091-02-03' + v_index
      );
      RAISE EXCEPTION 'direct INSERT accepted incomplete % booking', v_status;
    EXCEPTION WHEN invalid_parameter_value THEN
      IF SQLERRM <> 'booking commercial completion is required' THEN RAISE; END IF;
    END;
  END LOOP;
END;
$$;

INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out,
  agreed_total_amount_minor, currency, commercial_completion_status
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000410',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  'confirmed', DATE '2091-03-01', DATE '2091-03-03', 100000, 'EGP', 'complete'
);
DO $$
BEGIN
  BEGIN
    UPDATE public.bookings
    SET currency = NULL
    WHERE id = 'aaaaaaaa-0000-0000-0000-000000000410';
    RAISE EXCEPTION 'touching an operational booking cleared commercial data';
  EXCEPTION WHEN invalid_parameter_value THEN
    IF SQLERRM <> 'booking commercial completion is required' THEN RAISE; END IF;
  END;
END;
$$;

-- Model an incomplete historical operational row to prove direct inserts and
-- both stay RPCs fail at the event boundary. The replica setting is test-only.
INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000411',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  'draft', DATE '2091-04-01', DATE '2091-04-03'
);
SET session_replication_role = replica;
UPDATE public.bookings
SET status = 'confirmed'
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000411';
SET session_replication_role = origin;

DO $$
DECLARE
  v_actor uuid := (
    SELECT id FROM public.organization_memberships
    WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND user_id = '11111111-1111-1111-1111-111111111111'
  );
BEGIN
  BEGIN
    INSERT INTO public.booking_stay_events (
      organization_id, booking_id, event_type, actor_membership_id, idempotency_key
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000411', 'check_in', v_actor,
      'booking-integrity-direct-event-411'
    );
    RAISE EXCEPTION 'direct stay-event INSERT accepted an incomplete booking';
  EXCEPTION WHEN invalid_parameter_value THEN
    IF SQLERRM <> 'booking commercial completion is required before a stay event' THEN RAISE; END IF;
  END;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.record_booking_stay_event(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000411', 'check_in', NULL,
      'booking-integrity-legacy-event-411', NULL
    );
    RAISE EXCEPTION 'legacy stay RPC accepted an incomplete booking';
  EXCEPTION WHEN invalid_parameter_value THEN
    IF SQLERRM <> 'booking commercial completion is required before a stay event' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.record_commercial_booking_stay_event(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000411', 'check_in', NULL,
      'booking-integrity-canonical-event-411', NULL
    );
    RAISE EXCEPTION 'canonical stay RPC accepted an incomplete booking';
  EXCEPTION WHEN invalid_parameter_value THEN
    IF SQLERRM <> 'booking commercial completion is required before a stay event' THEN RAISE; END IF;
  END;
END;
$$;
RESET ROLE;

-- Commercial completion is draft-only; an identical draft retry is idempotent
-- while payload reuse with different terms is rejected.
DO $$
DECLARE
  v_status text;
  v_index integer := 0;
  v_booking_id uuid;
BEGIN
  FOREACH v_status IN ARRAY ARRAY['pending_approval', 'confirmed', 'checked_in', 'checked_out', 'completed', 'cancelled'] LOOP
    v_index := v_index + 1;
    v_booking_id := ('aaaaaaaa-0000-0000-0000-00000000042' || v_index)::uuid;
    INSERT INTO public.bookings (
      id, organization_id, property_id, client_id, status, check_in, check_out,
      agreed_total_amount_minor, currency, commercial_completion_status
    ) VALUES (
      v_booking_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000002', v_status,
      DATE '2091-05-01' + (v_index * 3), DATE '2091-05-03' + (v_index * 3),
      100000, 'EGP', 'complete'
    );
    BEGIN
      PERFORM public.complete_booking_commercial_snapshot(
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_booking_id,
        '200000', 'EGP', 'later state must reject',
        'booking-integrity-later-' || v_index, NULL
      );
      RAISE EXCEPTION 'commercial completion accepted % booking', v_status;
    EXCEPTION WHEN invalid_parameter_value THEN
      IF SQLERRM <> 'commercial snapshot can only be completed while booking is draft' THEN RAISE; END IF;
    END;
  END LOOP;
END;
$$;

INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000430',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  'draft', DATE '2091-07-01', DATE '2091-07-03'
);
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.complete_booking_commercial_snapshot(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000430', '300000', 'EGP',
  'first complete', 'booking-integrity-completion-430', NULL
);
SELECT public.complete_booking_commercial_snapshot(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000430', '300000', 'EGP',
  'same payload retry', 'booking-integrity-completion-430', NULL
);
DO $$
BEGIN
  BEGIN
    PERFORM public.complete_booking_commercial_snapshot(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000430', '301000', 'EGP',
      'different payload', 'booking-integrity-completion-430', NULL
    );
    RAISE EXCEPTION 'commercial completion key accepted a different payload';
  EXCEPTION WHEN unique_violation THEN
    IF SQLERRM NOT LIKE '%different payload%' THEN RAISE; END IF;
  END;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.audit_events
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND resource_id = 'aaaaaaaa-0000-0000-0000-000000000430'
        AND action = 'booking.commercial_completed') <> 1 THEN
    RAISE EXCEPTION 'identical commercial completion retry emitted duplicate audit evidence';
  END IF;
END;
$$;

-- An unexpired stale pending request is cancelled and replaced immediately.
INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out,
  agreed_total_amount_minor, currency, commercial_completion_status
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000440',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002', 'draft', DATE '2091-08-01', DATE '2091-08-03',
  400000, 'EGP', 'complete'
);
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '66666666-6666-6666-6666-666666666666', false);
SELECT public.request_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000440', 'booking-integrity-stale-pending-1', NULL
) AS stale_pending_id \gset
SELECT set_config('voya.test.booking_integrity_stale_pending_id', :'stale_pending_id', false);
RESET ROLE;
UPDATE public.bookings
SET agreed_total_amount_minor = 450000
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000440';
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '66666666-6666-6666-6666-666666666666', false);
SELECT public.request_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000440', 'booking-integrity-stale-pending-2', NULL
) AS fresh_pending_id \gset
SELECT set_config('voya.test.booking_integrity_fresh_pending_id', :'fresh_pending_id', false);
RESET ROLE;

DO $$
BEGIN
  IF current_setting('voya.test.booking_integrity_fresh_pending_id')::uuid
       = current_setting('voya.test.booking_integrity_stale_pending_id')::uuid
    OR (SELECT status FROM public.approval_requests WHERE id = current_setting('voya.test.booking_integrity_stale_pending_id')::uuid) <> 'cancelled'
    OR (SELECT proposal_snapshot->>'agreed_total_amount_minor' FROM public.approval_requests WHERE id = current_setting('voya.test.booking_integrity_fresh_pending_id')::uuid) <> '450000'
    OR (SELECT snapshot_hash FROM public.approval_requests WHERE id = current_setting('voya.test.booking_integrity_fresh_pending_id')::uuid)
       <> encode(extensions.digest((SELECT proposal_snapshot::text FROM public.approval_requests WHERE id = current_setting('voya.test.booking_integrity_fresh_pending_id')::uuid), 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'stale pending approval was not cancelled and refreshed';
  END IF;
END;
$$;

-- The same recovery applies to an unexpired approved request.
INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out,
  agreed_total_amount_minor, currency, commercial_completion_status
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000441',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002', 'draft', DATE '2091-09-01', DATE '2091-09-03',
  500000, 'EGP', 'complete'
);
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '66666666-6666-6666-6666-666666666666', false);
SELECT public.request_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000441', 'booking-integrity-stale-approved-1', NULL
) AS stale_approved_id \gset
SELECT set_config('voya.test.booking_integrity_stale_approved_id', :'stale_approved_id', false);
RESET ROLE;
UPDATE public.approval_requests
SET status = 'approved'
WHERE id = :'stale_approved_id';
UPDATE public.bookings
SET agreed_total_amount_minor = 550000
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000441';
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '66666666-6666-6666-6666-666666666666', false);
SELECT public.request_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000441', 'booking-integrity-stale-approved-2', NULL
) AS fresh_approved_id \gset
SELECT set_config('voya.test.booking_integrity_fresh_approved_id', :'fresh_approved_id', false);
RESET ROLE;

DO $$
BEGIN
  IF current_setting('voya.test.booking_integrity_fresh_approved_id')::uuid
       = current_setting('voya.test.booking_integrity_stale_approved_id')::uuid
    OR (SELECT status FROM public.approval_requests WHERE id = current_setting('voya.test.booking_integrity_stale_approved_id')::uuid) <> 'cancelled'
    OR (SELECT status FROM public.approval_requests WHERE id = current_setting('voya.test.booking_integrity_fresh_approved_id')::uuid) <> 'pending' THEN
    RAISE EXCEPTION 'stale approved request was not cancelled and refreshed';
  END IF;
END;
$$;

SELECT 'booking integrity remediation tests passed' AS result;
