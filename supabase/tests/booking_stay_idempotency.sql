-- R06: an organization-scoped stay-event key is bound to booking, type, and
-- normalized notes; a replay from a different request cannot return false success.
\set ON_ERROR_STOP on

BEGIN;
INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out,
  agreed_total_amount_minor, currency, commercial_completion_status, created_by_membership_id
) VALUES
  ('aaaaaaaa-0000-0000-0000-00000000b601', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
   'confirmed', DATE '2091-01-10', DATE '2091-01-12', 100000, 'EGP', 'complete',
   (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111')),
  ('aaaaaaaa-0000-0000-0000-00000000b602', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
   'confirmed', DATE '2091-02-10', DATE '2091-02-12', 100000, 'EGP', 'complete',
   (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111'));

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claim.email', 'owner@example.test', true);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal2"}', true);

SELECT public.record_commercial_booking_stay_event(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-00000000b601',
  'check_in', '  key handoff  ', 'r06-stay-event-key', 'aaaaaaaa-0000-0000-0000-00000000b611'
) AS first_event_id \gset
SELECT public.record_commercial_booking_stay_event(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-00000000b601',
  'check_in', 'key handoff', 'r06-stay-event-key', 'aaaaaaaa-0000-0000-0000-00000000b612'
) AS replay_event_id \gset
SELECT CASE WHEN :'first_event_id'::uuid = :'replay_event_id'::uuid THEN 'exact stay replay passed' ELSE (1 / 0)::text END;

DO $$
DECLARE v_rejected boolean;
BEGIN
  v_rejected := false;
  BEGIN
    PERFORM public.record_commercial_booking_stay_event(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-00000000b601',
      'check_out', 'key handoff', 'r06-stay-event-key', 'aaaaaaaa-0000-0000-0000-00000000b613'
    );
  EXCEPTION WHEN SQLSTATE '23505' THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'R06 regression: changed event type replay returned success'; END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.record_commercial_booking_stay_event(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-00000000b601',
      'check_in', 'different handoff', 'r06-stay-event-key', 'aaaaaaaa-0000-0000-0000-00000000b614'
    );
  EXCEPTION WHEN SQLSTATE '23505' THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'R06 regression: changed notes replay returned success'; END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.record_commercial_booking_stay_event(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-00000000b602',
      'check_in', 'key handoff', 'r06-stay-event-key', 'aaaaaaaa-0000-0000-0000-00000000b615'
    );
  EXCEPTION WHEN SQLSTATE '23505' THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'R06 regression: another booking reused the stay-event key'; END IF;
END;
$$;

RESET ROLE;
DO $$
BEGIN
  IF (SELECT status FROM public.bookings WHERE id = 'aaaaaaaa-0000-0000-0000-00000000b602') <> 'confirmed'
    OR (SELECT count(*) FROM public.booking_stay_events WHERE idempotency_key = 'r06-stay-event-key') <> 1 THEN
    RAISE EXCEPTION 'R06 conflict changed another booking or inserted a duplicate stay event';
  END IF;
END;
$$;
ROLLBACK;
SELECT 'R06 stay-event idempotency tests passed' AS result;
