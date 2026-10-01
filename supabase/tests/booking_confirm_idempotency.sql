-- R08: a booking-confirm command key must not confirm a second booking.
\set ON_ERROR_STOP on

BEGIN;
INSERT INTO auth.users (id, email)
VALUES ('e0e0e0e0-e0e0-40e0-80e0-e0e0e0e0e008', 'r08-manager@example.test')
ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email;
INSERT INTO public.profiles (id, display_name)
VALUES ('e0e0e0e0-e0e0-40e0-80e0-e0e0e0e0e008', 'R08 manager')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.organization_memberships (id, organization_id, user_id, role, status)
VALUES ('aaaaaaaa-0000-0000-0000-00000000b801', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'e0e0e0e0-e0e0-40e0-80e0-e0e0e0e0e008', 'manager', 'active')
ON CONFLICT (organization_id, user_id) DO UPDATE SET role = 'manager', status = 'active';

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claim.email', 'owner@example.test', true);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal2"}', true);
SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002', DATE '2092-05-10', DATE '2092-05-12',
  '100000', 'EGP', 'r08-draft-a-key', 'aaaaaaaa-0000-0000-0000-00000000b802'
) AS booking_a_id \gset
SELECT set_config('voya.r08_booking_a', :'booking_a_id', true);
SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002', DATE '2092-06-10', DATE '2092-06-12',
  '100000', 'EGP', 'r08-draft-b-key', 'aaaaaaaa-0000-0000-0000-00000000b803'
) AS booking_b_id \gset
SELECT set_config('voya.r08_booking_b', :'booking_b_id', true);
SELECT public.request_commercial_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_a_id', 'r08-approval-a',
  'aaaaaaaa-0000-0000-0000-00000000b804'
) AS approval_a_id \gset
SELECT public.request_commercial_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_b_id', 'r08-approval-b',
  'aaaaaaaa-0000-0000-0000-00000000b805'
) AS approval_b_id \gset
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'e0e0e0e0-e0e0-40e0-80e0-e0e0e0e0e008', true);
SELECT set_config('request.jwt.claim.email', 'r08-manager@example.test', true);
SELECT set_config('request.jwt.claims', '{"sub":"e0e0e0e0-e0e0-40e0-80e0-e0e0e0e0e008","email":"r08-manager@example.test","role":"authenticated","aal":"aal2"}', true);
SELECT public.decide_booking_approval('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'approval_a_id', 'approved', 'R08 proof A', 'aaaaaaaa-0000-0000-0000-00000000b806');
SELECT public.decide_booking_approval('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'approval_b_id', 'approved', 'R08 proof B', 'aaaaaaaa-0000-0000-0000-00000000b807');
SELECT public.confirm_commercial_booking('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_a_id', 'r08-confirm-shared-key', 'aaaaaaaa-0000-0000-0000-00000000b808');
DO $$
BEGIN
  IF NOT public.confirm_commercial_booking(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.r08_booking_a')::uuid,
    'r08-confirm-shared-key', 'aaaaaaaa-0000-0000-0000-00000000b809'
  ) THEN
    RAISE EXCEPTION 'R08 exact confirm replay returned false';
  END IF;
END;
$$;

DO $$
DECLARE v_rejected boolean := false;
BEGIN
  BEGIN
    PERFORM public.confirm_commercial_booking(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.r08_booking_b')::uuid,
      'r08-confirm-shared-key', 'aaaaaaaa-0000-0000-0000-00000000b810'
    );
  EXCEPTION WHEN SQLSTATE '23505' THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'R08 regression: a shared confirm key confirmed a different booking'; END IF;
END;
$$;
RESET ROLE;

DO $$
DECLARE
  v_booking_a uuid := current_setting('voya.r08_booking_a')::uuid;
  v_booking_b uuid := current_setting('voya.r08_booking_b')::uuid;
BEGIN
  IF (SELECT status FROM public.bookings WHERE id = v_booking_a) <> 'confirmed'
    OR (SELECT status FROM public.bookings WHERE id = v_booking_b) <> 'pending_approval'
    OR (SELECT count(*) FROM public.booking_v1_command_idempotency WHERE command_name = 'booking.confirm.v1' AND idempotency_key = 'r08-confirm-shared-key') <> 1 THEN
    RAISE EXCEPTION 'R08 changed the second booking or lost the original command binding';
  END IF;
END;
$$;
ROLLBACK;
SELECT 'R08 confirmation idempotency tests passed' AS result;
