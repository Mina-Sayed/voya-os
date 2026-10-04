-- R07: a draft-create key remains bound to its booking across approval and stay transitions.
\set ON_ERROR_STOP on

BEGIN;
INSERT INTO auth.users (id, email)
VALUES ('f0f0f0f0-f0f0-40f0-80f0-f0f0f0f0f007', 'r07-manager@example.test')
ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email;
INSERT INTO public.profiles (id, display_name)
VALUES ('f0f0f0f0-f0f0-40f0-80f0-f0f0f0f0f007', 'R07 manager')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.organization_memberships (id, organization_id, user_id, role, status)
VALUES ('aaaaaaaa-0000-0000-0000-00000000b701', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'f0f0f0f0-f0f0-40f0-80f0-f0f0f0f0f007', 'manager', 'active')
ON CONFLICT (organization_id, user_id) DO UPDATE SET role = 'manager', status = 'active';

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claim.email', 'owner@example.test', true);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal2"}', true);

SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002', DATE '2092-01-10', DATE '2092-01-12',
  '100000', 'EGP', 'r07-stable-create-key', 'aaaaaaaa-0000-0000-0000-00000000b702'
) AS original_booking_id \gset
SELECT set_config('voya.test.r07_booking_id', :'original_booking_id', true);
SELECT public.request_commercial_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'original_booking_id', 'r07-approval-key',
  'aaaaaaaa-0000-0000-0000-00000000b703'
) AS approval_id \gset

DO $$
DECLARE v_replay uuid;
BEGIN
  v_replay := public.create_commercial_booking_draft(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001',
    'aaaaaaaa-0000-0000-0000-000000000002', DATE '2092-01-10', DATE '2092-01-12',
    '100000', 'EGP', 'r07-stable-create-key', 'aaaaaaaa-0000-0000-0000-00000000b704'
  );
  IF v_replay <> current_setting('voya.test.r07_booking_id')::uuid THEN
    RAISE EXCEPTION 'R07 regression: create replay after pending approval returned a different booking';
  END IF;
END;
$$;

SELECT set_config('request.jwt.claim.sub', 'f0f0f0f0-f0f0-40f0-80f0-f0f0f0f0f007', true);
SELECT set_config('request.jwt.claim.email', 'r07-manager@example.test', true);
SELECT set_config('request.jwt.claims', '{"sub":"f0f0f0f0-f0f0-40f0-80f0-f0f0f0f0f007","email":"r07-manager@example.test","role":"authenticated","aal":"aal2"}', true);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'approval_id', 'approved', 'R07 proof',
  'aaaaaaaa-0000-0000-0000-00000000b705'
);
SELECT public.confirm_commercial_booking(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'original_booking_id', 'r07-confirm-key',
  'aaaaaaaa-0000-0000-0000-00000000b706'
);
SELECT public.record_commercial_booking_stay_event(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'original_booking_id', 'check_in', NULL, 'r07-check-in-key',
  'aaaaaaaa-0000-0000-0000-00000000b707'
);
SELECT public.record_commercial_booking_stay_event(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'original_booking_id', 'check_out', NULL, 'r07-check-out-key',
  'aaaaaaaa-0000-0000-0000-00000000b708'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claim.email', 'owner@example.test', true);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal2"}', true);
SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002', DATE '2092-01-10', DATE '2092-01-12',
  '100000', 'EGP', 'r07-stable-create-key', 'aaaaaaaa-0000-0000-0000-00000000b709'
) AS checked_out_replay_id \gset
SELECT CASE WHEN :'checked_out_replay_id'::uuid = :'original_booking_id'::uuid
  THEN 'R07 checked-out replay passed' ELSE (1 / 0)::text END;
RESET ROLE;
ROLLBACK;
SELECT 'R07 booking draft idempotency lifecycle tests passed' AS result;
