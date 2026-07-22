-- In-app notifications are recipient-scoped and browser reads use narrow RPCs.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.notifications', 'SELECT')
    OR has_table_privilege('authenticated', 'public.notifications', 'UPDATE') THEN
    RAISE EXCEPTION 'authenticated must not receive direct notification reads or updates';
  END IF;
END;
$$;

INSERT INTO public.notifications (
  id, organization_id, recipient_membership_id, category, title, body, dedupe_key
)
VALUES (
  'aaaaaaaa-0000-0000-0000-0000000000e1',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111'),
  'operational', 'تنبيه تشغيلي', 'تمت إضافة حظر توفر.', 'notification-test-a-1'
);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT count(*) FROM public.list_my_notifications('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 25);
SELECT public.mark_notification_read('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-0000000000e1');
RESET ROLE;

DO $$
BEGIN
  IF (SELECT read_at IS NOT NULL FROM public.notifications WHERE id = 'aaaaaaaa-0000-0000-0000-0000000000e1') IS NOT TRUE THEN
    RAISE EXCEPTION 'recipient read command did not set read timestamp';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE action = 'notification.read' AND outcome = 'success') <> 1 THEN
    RAISE EXCEPTION 'first notification read must append audit evidence';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_my_notifications('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 25);
    RAISE EXCEPTION 'suspended member must not read notifications';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;
