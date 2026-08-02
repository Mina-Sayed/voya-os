-- Operational task registry integration checks.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.operations_tasks', 'SELECT')
    OR has_table_privilege('authenticated', 'public.operations_tasks', 'UPDATE') THEN
    RAISE EXCEPTION 'browser role must use operational task RPCs';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_operations_task(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'check_in', 'تجهيز وصول عميل النيل', 'تحقق من المفاتيح والنظافة',
  '2026-08-09 12:00:00+00', 'aaaaaaaa-0000-0000-0000-000000000003', NULL, 'task-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000f1'
) AS task_id \gset

SELECT public.create_operations_task(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'check_in', 'تجهيز وصول عميل النيل', 'تحقق من المفاتيح والنظافة',
  '2026-08-09 12:00:00+00', 'aaaaaaaa-0000-0000-0000-000000000003', NULL, 'task-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000f2'
);

SELECT public.update_operations_task_status(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'task_id', 'in_progress', 'aaaaaaaa-0000-0000-0000-0000000000f3'
);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.list_operations_tasks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 50)) <> 1 THEN
    RAISE EXCEPTION 'idempotent task command must persist exactly one task';
  END IF;
  IF (SELECT count(*) FROM public.list_operations_tasks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 50) WHERE status = 'in_progress') <> 1 THEN
    RAISE EXCEPTION 'task status update must be visible through the read RPC';
  END IF;
END;
$$;

RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.outbox_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND event_type = 'operations.task.created') <> 1 THEN
    RAISE EXCEPTION 'task command must create one outbox event';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND action IN ('operations.task.created', 'operations.task.status_changed')) <> 2 THEN
    RAISE EXCEPTION 'task command/status must create audit evidence';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_operations_tasks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 50);
    RAISE EXCEPTION 'suspended viewer must not read operations tasks';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'operations task database integration tests passed' AS result;
