-- Schedule bounded pruning of expired source and account rate-limit buckets.
-- Source buckets are shared before an account bucket is allocated so a caller
-- cannot create unbounded rows by changing only the submitted email.
DO $$
DECLARE v_job_id bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_cron') THEN
    FOR v_job_id IN SELECT jobid FROM cron.job WHERE jobname = 'voya-auth-rate-limit-cleanup' LOOP
      PERFORM cron.unschedule(v_job_id);
    END LOOP;
    PERFORM cron.schedule(
      'voya-auth-rate-limit-cleanup',
      '13 * * * *',
      'SELECT public.purge_auth_rate_limit_buckets(86400, 500);'
    );
  ELSE
    RAISE NOTICE 'pg_cron is not installed; schedule voya-auth-rate-limit-cleanup after enabling the scheduler';
  END IF;
END;
$$;
