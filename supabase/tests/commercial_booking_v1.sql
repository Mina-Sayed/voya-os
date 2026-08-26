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
SELECT public.request_booking_amendment(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id',
  'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2050-01-10', DATE '2050-01-14', '3000000', 'EGP', 'تمديد الإقامة',
  'commercial-v1-amend-request-1', 'aaaaaaaa-0000-0000-0000-000000000506'
) AS amendment_replay_id \gset
SELECT CASE
  WHEN :'amendment_replay_id'::uuid = :'amendment_approval_id'::uuid THEN 'amendment idempotency replayed'
  ELSE (1 / 0)::text
END AS amendment_idempotency_check;
SELECT set_config('voya.test.amendment_approval_id', :'amendment_approval_id', false);

DO $$
DECLARE
  summary jsonb;
BEGIN
  SELECT request.proposal_summary INTO summary
  FROM public.list_approval_requests_v2('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 100) AS request
  WHERE request.id = current_setting('voya.test.amendment_approval_id')::uuid;

  IF summary IS NULL
    OR summary->>'checkIn' <> '2050-01-10'
    OR summary->>'checkOut' <> '2050-01-14'
    OR summary->>'amountMinor' <> '3000000'
    OR summary->>'currency' <> 'EGP'
    OR summary->>'reason' <> 'تمديد الإقامة'
    OR NULLIF(summary->>'propertyLabel', '') IS NULL
    OR NULLIF(summary->>'clientLabel', '') IS NULL THEN
    RAISE EXCEPTION 'amendment approval projection must expose the complete normalized safe summary';
  END IF;
END;
$$;
RESET ROLE;

-- A retry must replay the committed result before mutable operational-readiness
-- checks. Suspending the alternate checker after the first commit must not turn
-- the same idempotency key into a fresh authorization failure.
UPDATE public.organization_memberships
SET status = 'suspended', updated_at = timezone('utc', now())
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '11111111-1111-1111-1111-111111111111';

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
SELECT public.request_booking_amendment(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id',
  'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2050-01-10', DATE '2050-01-14', '3000000', 'EGP', 'تمديد الإقامة',
  'commercial-v1-amend-request-1', 'aaaaaaaa-0000-0000-0000-000000000506'
) AS amendment_replay_after_checker_change \gset
SELECT CASE
  WHEN :'amendment_replay_after_checker_change'::uuid = :'amendment_approval_id'::uuid THEN 'amendment replay ignores later readiness changes'
  ELSE (1 / 0)::text
END AS amendment_replay_after_checker_change_check;
RESET ROLE;

UPDATE public.organization_memberships
SET status = 'active', updated_at = timezone('utc', now())
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '11111111-1111-1111-1111-111111111111';

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'amendment_approval_id', 'approved', 'تمت مراجعة التعديل.',
  'aaaaaaaa-0000-0000-0000-000000000506'
);
SELECT public.execute_booking_amendment(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', :'amendment_approval_id', 'commercial-v1-amend-execute-1',
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

-- Two requests may snapshot the same booking version, but once one executes the
-- sibling proposal is stale and must be rejected at decision time rather than
-- becoming an approved request that can never execute.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
SELECT public.request_booking_amendment(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id',
  'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2050-01-10', DATE '2050-01-15', '3100000', 'EGP', 'تعديل أول',
  'commercial-v1-amend-stale-a', 'aaaaaaaa-0000-0000-0000-000000000509'
) AS stale_amendment_a \gset
SELECT public.request_booking_amendment(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id',
  'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2050-01-10', DATE '2050-01-16', '3200000', 'EGP', 'تعديل ثان',
  'commercial-v1-amend-stale-b', 'aaaaaaaa-0000-0000-0000-000000000510'
) AS stale_amendment_b \gset
SELECT set_config('voya.test.stale_amendment_b', :'stale_amendment_b', false);
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'stale_amendment_a', 'approved', 'اعتماد التعديل الأول.',
  'aaaaaaaa-0000-0000-0000-000000000511'
);
SELECT public.execute_booking_amendment(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', :'stale_amendment_a', 'commercial-v1-amend-stale-execute-a',
  'aaaaaaaa-0000-0000-0000-000000000512'
);

DO $$
DECLARE
  stale_rejected boolean := false;
BEGIN
  BEGIN
    PERFORM public.decide_booking_approval(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.stale_amendment_b')::uuid,
      'approved',
      'يجب رفض snapshot قديم.',
      'aaaaaaaa-0000-0000-0000-000000000513'
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    stale_rejected := true;
  END;

  IF NOT stale_rejected THEN
    RAISE EXCEPTION 'stale amendment proposal was approved after the booking version changed';
  END IF;
END;
$$;
RESET ROLE;

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