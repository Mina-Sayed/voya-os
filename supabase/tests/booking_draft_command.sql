-- The booking draft command is the first browser-callable booking mutation.
-- It must authenticate the actor, authorize the role, preserve idempotency,
-- and append audit evidence without granting table writes.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.bookings', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must not receive direct booking inserts';
  END IF;
END;
$$;

INSERT INTO auth.users (id)
VALUES ('44444444-4444-4444-4444-444444444444')
ON CONFLICT DO NOTHING;

INSERT INTO public.profiles (id, display_name)
VALUES ('44444444-4444-4444-4444-444444444444', 'Sales agent')
ON CONFLICT DO NOTHING;

INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '44444444-4444-4444-4444-444444444444',
  'sales_agent',
  'active'
)
ON CONFLICT DO NOTHING;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '44444444-4444-4444-4444-444444444444', false);

SELECT public.create_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2027-04-20', DATE '2027-04-23', 'draft-command-sales-1',
  'aaaaaaaa-0000-0000-0000-000000000093'
);

RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.bookings
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'draft'
        AND idempotency_key = 'draft-command-sales-1') <> 1 THEN
    RAISE EXCEPTION 'sales agent must be able to create a booking proposal';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2027-04-10',
  DATE '2027-04-13',
  'draft-command-a-1',
  'aaaaaaaa-0000-0000-0000-000000000090'
);

RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.bookings
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'draft'
        AND idempotency_key = 'draft-command-a-1') <> 1 THEN
    RAISE EXCEPTION 'authorized booking draft command did not persist a draft';
  END IF;

  IF (SELECT count(*)
      FROM public.audit_events AS audit
      JOIN public.bookings AS booking ON booking.id = audit.resource_id
      WHERE audit.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND audit.action = 'booking.draft_created'
        AND audit.outcome = 'success'
        AND booking.idempotency_key = 'draft-command-a-1') <> 1 THEN
    RAISE EXCEPTION 'booking draft command must append an audit event';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2027-04-10',
  DATE '2027-04-13',
  'draft-command-a-1',
  'aaaaaaaa-0000-0000-0000-000000000091'
);

RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.bookings
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND idempotency_key = 'draft-command-a-1') <> 1 THEN
    RAISE EXCEPTION 'same idempotency key must not create a second booking';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);

DO $$
BEGIN
  BEGIN
    PERFORM public.create_booking_draft(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000002',
      DATE '2027-05-10', DATE '2027-05-13', 'draft-command-denied',
      'aaaaaaaa-0000-0000-0000-000000000092'
    );
    RAISE EXCEPTION 'suspended user must not create a booking draft';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

RESET ROLE;
