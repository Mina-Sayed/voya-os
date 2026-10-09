-- R10/R15: approval recovery must be projected from current, tenant-scoped state.
\set ON_ERROR_STOP on

BEGIN;

INSERT INTO public.organizations (id, name, slug, default_locale, timezone, default_currency, status)
VALUES ('cccccccc-cccc-4ccc-8ccc-ccccccccccc1', 'R10/R15 approval test', 'r10-r15-approval-test', 'ar', 'Africa/Cairo', 'EGP', 'active');
INSERT INTO public.organization_memberships (id, organization_id, user_id, role, status)
VALUES ('cccc0000-0000-4000-8000-000000000111', 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1', '11111111-1111-1111-1111-111111111111', 'owner', 'active');
INSERT INTO public.properties (id, organization_id, code, name, timezone)
VALUES ('cccc0000-0000-4000-8000-000000000001', 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1', 'R10-01', 'R10 property', 'Africa/Cairo');
INSERT INTO public.clients (id, organization_id, display_name)
VALUES ('cccc0000-0000-4000-8000-000000000002', 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1', 'R10 client');

INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out,
  agreed_total_amount_minor, currency, commercial_completion_status, created_by_membership_id
) VALUES
  ('aaaaaaaa-0000-0000-0000-00000000a901', 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1',
   'cccc0000-0000-4000-8000-000000000001', 'cccc0000-0000-4000-8000-000000000002',
   'pending_approval', DATE '2088-02-01', DATE '2088-02-02', 100000, 'EGP', 'complete',
   'cccc0000-0000-4000-8000-000000000111'),
  ('aaaaaaaa-0000-0000-0000-00000000a902', 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1',
   'cccc0000-0000-4000-8000-000000000001', 'cccc0000-0000-4000-8000-000000000002',
   'pending_approval', DATE '2088-03-01', DATE '2088-03-02', 100000, 'EGP', 'complete',
   'cccc0000-0000-4000-8000-000000000111');

INSERT INTO public.approval_requests (
  id, organization_id, resource_type, resource_id, proposed_action, proposal_snapshot,
  snapshot_hash, requester_membership_id, status, expires_at, created_at
) VALUES
  ('aaaaaaaa-0000-0000-0000-00000000a911', 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1', 'booking',
   'aaaaaaaa-0000-0000-0000-00000000a901', 'booking.confirm', '{}'::jsonb,
   encode(extensions.digest('{}', 'sha256'), 'hex'),
   'cccc0000-0000-4000-8000-000000000111',
   'pending', timezone('utc', now()) - interval '1 day', timezone('utc', now()) - interval '60 days'),
  ('aaaaaaaa-0000-0000-0000-00000000a912', 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1', 'booking',
   'aaaaaaaa-0000-0000-0000-00000000a902', 'booking.confirm', '{}'::jsonb,
   encode(extensions.digest('{}', 'sha256'), 'hex'),
   'cccc0000-0000-4000-8000-000000000111',
   'pending', timezone('utc', now()) + interval '1 day', timezone('utc', now()) - interval '2 days'),
  ('aaaaaaaa-0000-0000-0000-00000000a913', 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1', 'booking',
   'aaaaaaaa-0000-0000-0000-00000000a902', 'booking.confirm', '{}'::jsonb,
   encode(extensions.digest('{}', 'sha256'), 'hex'),
   'cccc0000-0000-4000-8000-000000000111',
   'pending', timezone('utc', now()) - interval '3 days', timezone('utc', now()) - interval '5 days');

INSERT INTO public.approval_requests (
  organization_id, resource_type, resource_id, proposed_action, proposal_snapshot,
  snapshot_hash, requester_membership_id, status, expires_at, created_at
)
SELECT 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1', 'booking', gen_random_uuid(),
       'booking.confirm', '{}'::jsonb, encode(extensions.digest('{}', 'sha256'), 'hex'),
       'cccc0000-0000-4000-8000-000000000111',
       'rejected', timezone('utc', now()) + interval '1 day', timezone('utc', now()) - make_interval(mins => series.index)
FROM generate_series(1, 60) AS series(index);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claim.email', 'owner@example.test', true);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal1"}',
  true
);

DO $$
DECLARE
  v_state text;
BEGIN
  BEGIN
    PERFORM * FROM public.list_booking_approval_recovery_v1('cccccccc-cccc-4ccc-8ccc-ccccccccccc1');
    RAISE EXCEPTION 'R10 regression: expired booking approval recovery read unexpectedly accepted AAL1';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    GET STACKED DIAGNOSTICS v_state = MESSAGE_TEXT;
    IF v_state NOT LIKE '%MFA AAL2 is required%' THEN
      RAISE EXCEPTION 'R10 recovery was denied for a reason other than MFA: %', v_state;
    END IF;
  END;
  BEGIN
    PERFORM public.list_dashboard_approval_work_v1('cccccccc-cccc-4ccc-8ccc-ccccccccccc1', 4);
    RAISE EXCEPTION 'R15 regression: dashboard approval queue unexpectedly accepted AAL1';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    GET STACKED DIAGNOSTICS v_state = MESSAGE_TEXT;
    IF v_state NOT LIKE '%MFA AAL2 is required%' THEN
      RAISE EXCEPTION 'R15 dashboard approvals were denied for a reason other than MFA: %', v_state;
    END IF;
  END;
END;
$$;

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal2"}',
  true
);
SELECT set_config('request.jwt.claim.aal', 'aal2', true);

DO $$
DECLARE
  v_recovery_ids uuid[];
  v_dashboard jsonb;
BEGIN
  SELECT array_agg(recovery.booking_id ORDER BY recovery.booking_id)
  INTO v_recovery_ids
  FROM public.list_booking_approval_recovery_v1('cccccccc-cccc-4ccc-8ccc-ccccccccccc1') AS recovery;
  IF v_recovery_ids IS DISTINCT FROM ARRAY['aaaaaaaa-0000-0000-0000-00000000a901'::uuid] THEN
    RAISE EXCEPTION 'R10 expected only the booking whose latest approval expired, got %', v_recovery_ids;
  END IF;

  v_dashboard := public.list_dashboard_approval_work_v1('cccccccc-cccc-4ccc-8ccc-ccccccccccc1', 4);
  IF (v_dashboard->>'pending_count')::integer <> 3 THEN
    RAISE EXCEPTION 'R15 expected exact count of 3 pending approvals independent of closed history, got %', v_dashboard->>'pending_count';
  END IF;
  IF jsonb_array_length(v_dashboard->'approvals') <> 3
    OR NOT (v_dashboard->'approvals' @> '[{"id":"aaaaaaaa-0000-0000-0000-00000000a911","status":"pending"}]'::jsonb)
    OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_dashboard->'approvals') AS item
      WHERE item->>'status' <> 'pending'
    ) THEN
    RAISE EXCEPTION 'R15 dashboard preview must contain only pending work: %', v_dashboard->'approvals';
  END IF;
END;
$$;

RESET ROLE;

DO $$
BEGIN
  IF has_function_privilege('anon', 'public.list_booking_approval_recovery_v1(uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.list_dashboard_approval_work_v1(uuid,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'R10/R15 approval RPCs must not be executable by anon';
  END IF;
END;
$$;

ROLLBACK;
SELECT 'Approval recovery and dashboard work-queue tests passed' AS result;
