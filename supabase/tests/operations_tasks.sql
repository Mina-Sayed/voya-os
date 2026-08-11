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

DO $$
DECLARE
  v_actor uuid := (
    SELECT id FROM public.organization_memberships
    WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND user_id = '11111111-1111-1111-1111-111111111111'
  );
BEGIN
  INSERT INTO public.operations_tasks (
    id, organization_id, task_type, title, status,
    created_by_membership_id, idempotency_key
  ) VALUES
    ('aaaaaaaa-0000-0000-0000-000000000401', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'state_test', 'Open to completed', 'open', v_actor, 'task-state-401'),
    ('aaaaaaaa-0000-0000-0000-000000000402', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'state_test', 'Open to cancelled', 'open', v_actor, 'task-state-402'),
    ('aaaaaaaa-0000-0000-0000-000000000403', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'state_test', 'In progress to cancelled', 'open', v_actor, 'task-state-403');
END;
$$;

SELECT set_config(
  'voya.test.operations_task_id',
  (
    SELECT id::text
    FROM public.operations_tasks
    WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND idempotency_key = 'task-a-1'
  ),
  false
);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
DECLARE
  v_existing_task uuid := current_setting('voya.test.operations_task_id')::uuid;
BEGIN
  PERFORM public.update_operations_task_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_existing_task, 'completed', NULL
  );
  BEGIN
    PERFORM public.update_operations_task_status(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_existing_task, 'open', NULL
    );
    RAISE EXCEPTION 'completed operations task was reopened';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  PERFORM public.update_operations_task_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000401', 'open', NULL
  );
  PERFORM public.update_operations_task_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000401', 'completed', NULL
  );
  BEGIN
    PERFORM public.update_operations_task_status(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000401', 'in_progress', NULL
    );
    RAISE EXCEPTION 'completed operations task moved to in-progress';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  PERFORM public.update_operations_task_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000402', 'cancelled', NULL
  );
  BEGIN
    PERFORM public.update_operations_task_status(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000402', 'open', NULL
    );
    RAISE EXCEPTION 'cancelled operations task was reopened';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  PERFORM public.update_operations_task_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000403', 'in_progress', NULL
  );
  PERFORM public.update_operations_task_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000403', 'cancelled', NULL
  );
END;
$$;
RESET ROLE;

SELECT 'operations task database integration tests passed' AS result;
