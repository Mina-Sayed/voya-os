-- One-time schedule migrations can run before project Vault secrets exist.
-- This operator-only reconciler can be called after those secrets are added.
CREATE OR REPLACE FUNCTION public.reconcile_outbox_dispatch_scheduler_v1()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_dispatch_url text;
  v_worker_secret text;
  v_job_id bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_cron')
    OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_net')
    OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'supabase_vault') THEN
    RAISE EXCEPTION 'outbox scheduler extensions are not installed' USING ERRCODE = '55000';
  END IF;
  SELECT decrypted_secret INTO v_dispatch_url
  FROM vault.decrypted_secrets WHERE name = 'outbox_dispatch_url';
  SELECT decrypted_secret INTO v_worker_secret
  FROM vault.decrypted_secrets WHERE name = 'outbox_worker_secret';
  IF v_dispatch_url IS NULL OR v_worker_secret IS NULL
    OR char_length(v_worker_secret) < 32
    OR (v_dispatch_url !~ '^https://[^[:space:]]+$'
      AND v_dispatch_url !~ '^http://(127[.]0[.]0[.]1|localhost):[0-9]+/functions/v1/outbox-dispatch$') THEN
    RAISE EXCEPTION 'outbox scheduler Vault secrets are missing or invalid' USING ERRCODE = '55000';
  END IF;

  FOR v_job_id IN SELECT jobid FROM cron.job WHERE jobname = 'voya-os-outbox-dispatch' LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;
  PERFORM cron.schedule(
    'voya-os-outbox-dispatch',
    '* * * * *',
    $job$
      SELECT net.http_post(
        url := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'outbox_dispatch_url'),
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'outbox_worker_secret')
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 10000
      );
    $job$
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.outbox_dispatch_scheduler_ready_v1()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_job_id bigint;
  v_command text;
  v_dispatch_url text;
  v_worker_secret text;
  v_expected_command constant text := $expected$
    SELECT net.http_post(
      url := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'outbox_dispatch_url'),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'outbox_worker_secret')
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000
    );
  $expected$;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_cron')
    OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_net')
    OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'supabase_vault')
    OR pg_catalog.to_regclass('vault.decrypted_secrets') IS NULL THEN
    RETURN false;
  END IF;
  SELECT job.jobid, job.command INTO v_job_id, v_command
  FROM cron.job AS job
  WHERE job.jobname = 'voya-os-outbox-dispatch' AND job.active
  ORDER BY job.jobid DESC LIMIT 1;
  IF v_job_id IS NULL THEN RETURN false; END IF;
  IF pg_catalog.regexp_replace(pg_catalog.btrim(v_command), '[[:space:]]+', ' ', 'g')
      IS DISTINCT FROM pg_catalog.regexp_replace(pg_catalog.btrim(v_expected_command), '[[:space:]]+', ' ', 'g') THEN
    RETURN false;
  END IF;

  SELECT decrypted_secret INTO v_dispatch_url
  FROM vault.decrypted_secrets WHERE name = 'outbox_dispatch_url';
  SELECT decrypted_secret INTO v_worker_secret
  FROM vault.decrypted_secrets WHERE name = 'outbox_worker_secret';
  IF v_dispatch_url IS NULL OR v_worker_secret IS NULL
    OR char_length(v_worker_secret) < 32
    OR (v_dispatch_url !~ '^https://[^[:space:]]+$'
      AND v_dispatch_url !~ '^http://(127[.]0[.]0[.]1|localhost):[0-9]+/functions/v1/outbox-dispatch$') THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1 FROM cron.job_run_details AS run
    WHERE run.jobid = v_job_id AND run.status = 'succeeded'
      AND run.end_time >= timezone('utc', now()) - interval '3 minutes'
  ) AND EXISTS (
    SELECT 1 FROM public.outbox_worker_runs AS worker
    WHERE worker.status = 'completed'
      AND worker.started_at >= timezone('utc', now()) - interval '3 minutes'
      AND worker.finished_at >= timezone('utc', now()) - interval '3 minutes'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.reconcile_outbox_dispatch_scheduler_v1() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.outbox_dispatch_scheduler_ready_v1() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.outbox_dispatch_scheduler_ready_v1() TO service_role;
