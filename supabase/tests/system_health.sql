-- System health is an aggregate boundary; worker facts and task notifications
-- must not become browser-readable tables.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.outbox_worker_runs', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated must not read worker run rows directly';
  END IF;
  IF has_function_privilege('authenticated', 'public.start_outbox_worker_run(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must not start worker runs';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.get_system_health_v1(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'owner health aggregate must be callable';
  END IF;
END;
$$;

INSERT INTO public.outbox_events (
  id, organization_id, event_type, schema_version, dedupe_key, payload,
  state, available_at, last_error_code
)
VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000f1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'organization.invitation.send_requested', 1, 'health-email-pending', '{}'::jsonb, 'pending', '2026-08-16 08:00:00+00', NULL),
  ('aaaaaaaa-0000-0000-0000-0000000000f2', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'organization.invitation.send_requested', 1, 'health-email-review', '{}'::jsonb, 'needs_review', '2026-08-16 08:01:00+00', 'email_provider_error'),
  ('aaaaaaaa-0000-0000-0000-0000000000f3', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp.message.send_requested', 1, 'health-whatsapp-dead', '{}'::jsonb, 'dead_letter', '2026-08-16 08:02:00+00', 'whatsapp_rejected'),
  ('aaaaaaaa-0000-0000-0000-0000000000f4', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ai.run.requested', 1, 'health-ai-dead', jsonb_build_object('run_id', 'aaaaaaaa-0000-0000-0000-0000000000f5'), 'dead_letter', '2026-08-16 08:03:00+00', 'ai_provider_error');

INSERT INTO public.ai_runs (
  id, organization_id, agent_kind, agent_version, status, purpose,
  model_name, prompt_version, initiated_by_membership_id, idempotency_key,
  finished_at, error_code
)
VALUES (
  'aaaaaaaa-0000-0000-0000-0000000000f5',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'sales', 'registry-v1', 'failed', 'فشل اختبار الصحة',
  'test-model', 'test-prompt',
  (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111'),
  'health-ai-run', '2026-08-16 08:04:00+00', 'ai_provider_error'
);

SET ROLE service_role;
SELECT public.start_outbox_worker_run('health-worker') AS worker_run_id \gset
SELECT public.finish_outbox_worker_run(:'worker_run_id', 'health-worker', 'completed', 4, 1, 1, 1, 1, NULL);
RESET ROLE;

INSERT INTO public.operations_tasks (
  id, organization_id, task_type, title, status, due_at,
  assigned_membership_id, created_by_membership_id, idempotency_key
)
SELECT
  'aaaaaaaa-0000-0000-0000-0000000000f6',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'check_in', 'مهمة متأخرة للاختبار', 'open', '2026-08-10 08:00:00+00',
  membership.id, membership.id, 'health-overdue-task'
FROM public.organization_memberships AS membership
WHERE membership.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND membership.user_id = '11111111-1111-1111-1111-111111111111';

SET ROLE service_role;
SELECT public.emit_overdue_task_notifications('health-worker', '2026-08-17 08:00:00+00', 100);
SELECT public.emit_overdue_task_notifications('health-worker', '2026-08-17 08:00:00+00', 100);
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT * FROM public.get_system_health_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
RESET ROLE;

DO $$
DECLARE
  v_health record;
BEGIN
  SELECT * INTO v_health FROM public.get_system_health_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  IF v_health.database_status <> 'ok' OR v_health.last_worker_status <> 'completed' THEN
    RAISE EXCEPTION 'health aggregate must report database and worker status';
  END IF;
  IF v_health.pending_outbox_count < 1 OR v_health.dead_letter_count < 2 THEN
    RAISE EXCEPTION 'health aggregate must count pending and dead-letter events';
  END IF;
  IF v_health.email_failure_count < 1 OR v_health.whatsapp_failure_count < 1 OR v_health.ai_failure_count < 1 THEN
    RAISE EXCEPTION 'health aggregate must classify channel failures';
  END IF;
  IF (SELECT count(*) FROM public.notifications WHERE dedupe_key = 'operations-task-overdue:aaaaaaaa-0000-0000-0000-0000000000f6') <> 1 THEN
    RAISE EXCEPTION 'overdue task must emit exactly one notification';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE action = 'operations.task.overdue' AND resource_id = 'aaaaaaaa-0000-0000-0000-0000000000f6') <> 1 THEN
    RAISE EXCEPTION 'overdue task must emit one system audit event';
  END IF;
END;
$$;

SET ROLE service_role;
SELECT public.start_outbox_worker_run('health-worker-running') AS running_worker_run_id \gset
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
DECLARE
  v_health record;
BEGIN
  SELECT * INTO v_health FROM public.get_system_health_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  IF v_health.last_worker_status <> 'running' OR v_health.last_worker_run_at IS NULL THEN
    RAISE EXCEPTION 'health aggregate must expose a running worker start time';
  END IF;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.get_system_health_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'suspended viewer must not read system health';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'system health and overdue task database integration tests passed' AS result;
