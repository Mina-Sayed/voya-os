-- Commercial booking draft command is the only browser-callable booking creation path.
-- Legacy booking draft creation remains installed for migration history only and must not
-- be executable by browser roles.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.bookings', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must not receive direct booking inserts';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.create_booking_draft(uuid,uuid,uuid,date,date,text,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated must not execute the legacy booking draft RPC';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.create_commercial_booking_draft(uuid,uuid,uuid,date,date,text,text,text,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated must execute the commercial booking draft RPC';
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

SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2027-04-20', DATE '2027-04-23', '2500000', 'EGP',
  'draft-command-sales-1',
  'aaaaaaaa-0000-0000-0000-000000000093'
);

-- Exact retries return the same draft instead of creating another row.
SELECT public.create_commercial_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2027-04-20', DATE '2027-04-23', '2500000', 'EGP',
  'draft-command-sales-1',
  'aaaaaaaa-0000-0000-0000-000000000094'
);

RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.bookings
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'draft'
        AND commercial_completion_status = 'complete'
        AND agreed_total_amount_minor = 2500000
        AND currency = 'EGP'
        AND idempotency_key = 'draft-command-sales-1') <> 1 THEN
    RAISE EXCEPTION 'sales agent commercial booking draft was not persisted exactly once';
  END IF;

  IF (SELECT count(*)
      FROM public.audit_events AS audit
      JOIN public.bookings AS booking ON booking.id = audit.resource_id
      WHERE audit.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND audit.action = 'booking.commercial_draft_created'
        AND audit.outcome = 'success'
        AND booking.idempotency_key = 'draft-command-sales-1') <> 1 THEN
    RAISE EXCEPTION 'commercial booking draft command must append one audit event';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);

DO $$
BEGIN
  BEGIN
    PERFORM public.create_commercial_booking_draft(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000002',
      DATE '2027-05-10', DATE '2027-05-13', '2500000', 'EGP',
      'draft-command-denied',
      'aaaaaaaa-0000-0000-0000-000000000092'
    );
    RAISE EXCEPTION 'suspended user must not create a commercial booking draft';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

RESET ROLE;

SELECT 'commercial booking draft command tests passed' AS result;
