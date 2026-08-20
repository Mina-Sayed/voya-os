-- Terminal email/WhatsApp delivery failures produce one safe internal notice
-- per active owner/manager without exposing provider payloads.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.outbox_events', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.notifications', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must not mutate delivery state or notifications directly';
  END IF;
  IF to_regprocedure('public.notify_outbox_delivery_failure()') IS NULL THEN
    RAISE EXCEPTION 'delivery failure notification trigger is missing';
  END IF;
END;
$$;

INSERT INTO public.outbox_events (
  id, organization_id, event_type, schema_version, dedupe_key, payload,
  state, available_at, locked_by, locked_until
)
VALUES (
  'aaaaaaaa-0000-0000-0000-0000000000fe',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'whatsapp.message.send_requested',
  1,
  'delivery-failure-test',
  jsonb_build_object('body', 'لا يجب أن يظهر هذا النص في الإشعار'),
  'processing',
  '2050-01-01 00:00:00+00',
  'delivery-failure-test-worker',
  '2050-01-01 01:00:00+00'
);

UPDATE public.outbox_events
SET state = 'dead_letter',
    locked_by = NULL,
    locked_until = NULL,
    last_error_code = 'provider_permanent'
WHERE id = 'aaaaaaaa-0000-0000-0000-0000000000fe';

DO $$
DECLARE
  v_owner_membership uuid;
  v_manager_membership uuid;
  v_notice_count integer;
BEGIN
  SELECT id INTO v_owner_membership FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111';
  SELECT id INTO v_manager_membership FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '55555555-5555-5555-5555-555555555555';
  SELECT count(*) INTO v_notice_count
  FROM public.notifications
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND resource_type = 'outbox_event'
    AND resource_id = 'aaaaaaaa-0000-0000-0000-0000000000fe';
  IF v_notice_count <> 2 THEN
    RAISE EXCEPTION 'terminal delivery failure must notify each active owner/manager';
  END IF;
  IF (SELECT body FROM public.notifications WHERE recipient_membership_id = v_owner_membership AND resource_id = 'aaaaaaaa-0000-0000-0000-0000000000fe') LIKE '%لا يجب أن يظهر%' THEN
    RAISE EXCEPTION 'delivery failure notice must not expose provider payload';
  END IF;
  IF (SELECT count(*) FROM public.notifications WHERE recipient_membership_id IN (v_owner_membership, v_manager_membership) AND resource_id = 'aaaaaaaa-0000-0000-0000-0000000000fe' AND dedupe_key LIKE 'outbox-delivery-failure:aaaaaaaa-0000-0000-0000-0000000000fe:dead_letter:provider_permanent:%') <> 2 THEN
    RAISE EXCEPTION 'delivery failure notice must be idempotent';
  END IF;
END;
$$;

SELECT 'delivery failure notification database integration tests passed' AS result;
