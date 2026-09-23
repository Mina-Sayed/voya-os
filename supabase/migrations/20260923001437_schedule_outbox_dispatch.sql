-- Local Supabase E2E runs may not have provider/worker credentials. In that
-- case keep the database bootable and skip only the cron job; managed
-- staging/production create it after the per-project Vault secrets are set.
DO $do$
DECLARE
  v_dispatch_url text;
  v_worker_secret text;
BEGIN
  SELECT decrypted_secret INTO v_dispatch_url
  FROM vault.decrypted_secrets
  WHERE name = 'outbox_dispatch_url';

  SELECT decrypted_secret INTO v_worker_secret
  FROM vault.decrypted_secrets
  WHERE name = 'outbox_worker_secret';

  IF v_dispatch_url IS NULL OR v_worker_secret IS NULL THEN
    RAISE NOTICE 'Skipping outbox-dispatch Cron job because its Vault secrets are not configured';
    RETURN;
  END IF;

  -- Supabase Edge runtime secrets remain the source for the worker itself.
  -- Cron reads the same bearer token from Vault so it never enters the repo.
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
END;
$do$;
