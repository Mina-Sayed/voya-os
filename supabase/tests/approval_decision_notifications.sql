-- Approval decisions notify the requester exactly once and keep the browser
-- role away from the underlying approval/notification tables.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.approval_decisions', 'INSERT')
    OR has_table_privilege('authenticated', 'public.notifications', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must use approval RPCs and notification reads';
  END IF;
  IF to_regprocedure('public.notify_booking_approval_decision()') IS NULL THEN
    RAISE EXCEPTION 'approval decision notification trigger is missing';
  END IF;
END;
$$;

INSERT INTO public.approval_requests (
  id, organization_id, resource_type, resource_id, proposed_action,
  proposal_snapshot, snapshot_hash, requester_membership_id, status, expires_at
)
VALUES
  (
    'aaaaaaaa-0000-0000-0000-0000000000fa',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'booking', 'aaaaaaaa-0000-0000-0000-000000000003', 'booking.confirm',
    '{}'::jsonb, repeat('0', 64),
    (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111'),
    'pending', '2050-01-01 00:00:00+00'
  ),
  (
    'aaaaaaaa-0000-0000-0000-0000000000fb',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'booking', 'aaaaaaaa-0000-0000-0000-000000000003', 'booking.amend',
    '{}'::jsonb, repeat('1', 64),
    (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '55555555-5555-5555-5555-555555555555'),
    'pending', '2050-01-01 00:00:00+00'
  );

INSERT INTO public.approval_decisions (
  id, organization_id, approval_request_id, approver_membership_id, decision, reason
)
VALUES
  (
    'aaaaaaaa-0000-0000-0000-0000000000fc',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-0000000000fa',
    (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '55555555-5555-5555-5555-555555555555'),
    'approved', 'تمت المراجعة.'
  ),
  (
    'aaaaaaaa-0000-0000-0000-0000000000fd',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-0000000000fb',
    (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111'),
    'rejected', 'تحتاج إلى تعديل.'
  );

DO $$
DECLARE
  v_owner_membership uuid;
  v_manager_membership uuid;
BEGIN
  SELECT id INTO v_owner_membership FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111';
  SELECT id INTO v_manager_membership FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '55555555-5555-5555-5555-555555555555';
  IF (SELECT count(*) FROM public.notifications WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND recipient_membership_id = v_owner_membership AND dedupe_key = 'booking-approval-result:aaaaaaaa-0000-0000-0000-0000000000fa:approved') <> 1
    OR (SELECT count(*) FROM public.notifications WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND recipient_membership_id = v_manager_membership AND dedupe_key = 'booking-approval-result:aaaaaaaa-0000-0000-0000-0000000000fb:rejected') <> 1 THEN
    RAISE EXCEPTION 'approval result must notify the requester';
  END IF;
  IF (SELECT title FROM public.notifications WHERE dedupe_key = 'booking-approval-result:aaaaaaaa-0000-0000-0000-0000000000fa:approved') <> 'تم اعتماد طلب الحجز'
    OR (SELECT title FROM public.notifications WHERE dedupe_key = 'booking-approval-result:aaaaaaaa-0000-0000-0000-0000000000fb:rejected') <> 'تم رفض طلب الحجز' THEN
    RAISE EXCEPTION 'approval result notification copy is incorrect';
  END IF;
END;
$$;

SELECT 'approval decision notification database integration tests passed' AS result;
