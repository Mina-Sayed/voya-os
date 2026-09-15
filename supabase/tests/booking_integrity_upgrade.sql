-- Upgrade-boundary regression for legacy completion idempotency keys.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF (SELECT payload_hash IS NULL
      FROM public.booking_v1_command_idempotency
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND command_name = 'booking.commercial.complete'
        AND idempotency_key = 'booking-integrity-upgrade-k1') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'ambiguous legacy completion key must remain fail-closed';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);

-- A new key changes the draft terms after the migration boundary.
SELECT public.complete_booking_commercial_snapshot(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000461', '200000', 'EGP',
  'upgrade K2', 'booking-integrity-upgrade-k2', NULL
);

-- The original payload cannot be reconstructed from the legacy schema, so a
-- retry fails closed and must not mutate the newer terms stored on the draft.
DO $$
BEGIN
  BEGIN
    PERFORM public.complete_booking_commercial_snapshot(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000461', '100000', 'EGP',
      'upgrade K1 retry', 'booking-integrity-upgrade-k1', NULL
    );
    RAISE EXCEPTION 'ambiguous legacy completion key was accepted';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    IF SQLERRM NOT LIKE '%no stable payload hash%' THEN RAISE; END IF;
  END;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT agreed_total_amount_minor FROM public.bookings
      WHERE id = 'aaaaaaaa-0000-0000-0000-000000000461') <> 200000
    OR (SELECT currency FROM public.bookings
        WHERE id = 'aaaaaaaa-0000-0000-0000-000000000461') <> 'EGP'
    OR (SELECT count(*) FROM public.audit_events
        WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
          AND resource_id = 'aaaaaaaa-0000-0000-0000-000000000461'
          AND action = 'booking.commercial_completed') <> 1 THEN
    RAISE EXCEPTION 'legacy completion retry mutated the newer terms or emitted duplicate evidence';
  END IF;
END;
$$;

-- A legacy key whose terms cannot be reconstructed is also fail-closed.
INSERT INTO public.booking_v1_command_idempotency (
  organization_id, command_name, idempotency_key, booking_id
) VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'booking.commercial.complete',
  'booking-integrity-upgrade-null-hash', 'aaaaaaaa-0000-0000-0000-000000000461'
);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.complete_booking_commercial_snapshot(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000461', '200000', 'EGP',
      'unrecoverable legacy key', 'booking-integrity-upgrade-null-hash', NULL
    );
    RAISE EXCEPTION 'unrecoverable legacy completion key was accepted';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    IF SQLERRM NOT LIKE '%no stable payload hash%' THEN RAISE; END IF;
  END;
END;
$$;
RESET ROLE;

SELECT 'booking integrity upgrade tests passed' AS result;
