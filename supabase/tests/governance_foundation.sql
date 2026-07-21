-- Run after tenancy_booking_foundation.sql and the governance migration.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('public.approval_requests') IS NULL THEN
    RAISE EXCEPTION 'approval_requests table is required';
  END IF;
  IF to_regclass('public.audit_events') IS NULL THEN
    RAISE EXCEPTION 'audit_events table is required';
  END IF;
END;
$$;

INSERT INTO public.approval_requests (
  id, organization_id, resource_type, resource_id, proposed_action, proposal_snapshot, snapshot_hash, requester_membership_id
)
VALUES (
  'aaaaaaaa-0000-0000-0000-000000000010',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'booking',
  'aaaaaaaa-0000-0000-0000-000000000003',
  'booking.confirm',
  '{"bookingId":"aaaaaaaa-0000-0000-0000-000000000003"}'::jsonb,
  repeat('a', 64),
  (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111')
);

DO $$
DECLARE
  requester_id uuid;
BEGIN
  SELECT id INTO requester_id
  FROM public.organization_memberships
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND user_id = '11111111-1111-1111-1111-111111111111';

  BEGIN
    INSERT INTO public.approval_decisions (organization_id, approval_request_id, approver_membership_id, decision, reason)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000010', requester_id, 'approved', 'Self approval attempt');
    RAISE EXCEPTION 'expected self approval to fail';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.approval_requests (organization_id, resource_type, resource_id, proposed_action, proposal_snapshot, snapshot_hash, requester_membership_id)
    VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'booking',
      'aaaaaaaa-0000-0000-0000-000000000003',
      'booking.confirm',
      '{}'::jsonb,
      repeat('b', 64),
      (SELECT id FROM public.organization_memberships WHERE organization_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' AND user_id = '22222222-2222-2222-2222-222222222222')
    );
    RAISE EXCEPTION 'expected cross-tenant requester reference to fail';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;
END;
$$;

INSERT INTO public.audit_events (id, organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome)
VALUES (
  'aaaaaaaa-0000-0000-0000-000000000011',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'user',
  (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111'),
  'booking.proposed',
  'booking',
  'aaaaaaaa-0000-0000-0000-000000000003',
  'success'
);

DO $$
BEGIN
  BEGIN
    UPDATE public.audit_events SET action = 'tampered' WHERE id = 'aaaaaaaa-0000-0000-0000-000000000011';
    RAISE EXCEPTION 'expected audit mutation to fail';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    DELETE FROM public.audit_events WHERE id = 'aaaaaaaa-0000-0000-0000-000000000011';
    RAISE EXCEPTION 'expected audit deletion to fail';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  BEGIN
    INSERT INTO public.audit_events (organization_id, actor_type, action, resource_type, resource_id, outcome)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'user', 'tamper.attempt', 'audit_event', gen_random_uuid(), 'denied');
    RAISE EXCEPTION 'authenticated browser role must not write audit events';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'governance database integration tests passed' AS result;
