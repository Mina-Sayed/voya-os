\set ON_ERROR_STOP on

DO $$
DECLARE
  v_ready_definition text;
BEGIN
  IF to_regprocedure('public.reconcile_outbox_dispatch_scheduler_v1()') IS NULL
    OR to_regprocedure('public.outbox_dispatch_scheduler_ready_v1()') IS NULL THEN
    RAISE EXCEPTION 'outbox scheduler reconciliation RPCs are missing';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.outbox_dispatch_scheduler_ready_v1()', 'EXECUTE')
    OR has_function_privilege('anon', 'public.outbox_dispatch_scheduler_ready_v1()', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.outbox_dispatch_scheduler_ready_v1()', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.reconcile_outbox_dispatch_scheduler_v1()', 'EXECUTE') THEN
    RAISE EXCEPTION 'scheduler inspection/reconciliation RPC grants are too broad';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_cron')
    AND public.outbox_dispatch_scheduler_ready_v1() THEN
    RAISE EXCEPTION 'readiness cannot claim dispatch when pg_cron is absent';
  END IF;
  SELECT pg_get_functiondef('public.outbox_dispatch_scheduler_ready_v1()'::regprocedure)
  INTO v_ready_definition;
  IF v_ready_definition NOT LIKE '%pg_net%'
    OR v_ready_definition NOT LIKE '%supabase_vault%'
    OR v_ready_definition NOT LIKE '%job.command%'
    OR v_ready_definition NOT LIKE '%net.http_post%'
    OR v_ready_definition NOT LIKE '%outbox_dispatch_url%'
    OR v_ready_definition NOT LIKE '%outbox_worker_secret%'
    OR v_ready_definition NOT LIKE '%run.status = ''succeeded''%'
    OR v_ready_definition NOT LIKE '%public.outbox_worker_runs%'
    OR v_ready_definition NOT LIKE '%worker.status = ''completed''%'
    OR v_ready_definition NOT LIKE '%worker.finished_at >=%' THEN
    RAISE EXCEPTION 'scheduler readiness omits command, extension, secret, cron freshness, or worker completion validation';
  END IF;
END;
$$;

SELECT 'outbox scheduler reconciliation contract passed' AS result;
