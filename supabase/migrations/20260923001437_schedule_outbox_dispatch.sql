-- Require per-project Vault credentials before creating the recurring job.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM vault.decrypted_secrets WHERE name = 'outbox_dispatch_url'
  ) OR NOT EXISTS (
    SELECT 1 FROM vault.decrypted_secrets WHERE name = 'outbox_worker_secret'
  ) THEN
    RAISE EXCEPTION 'Configure outbox_dispatch_url and outbox_worker_secret in Vault before scheduling outbox-dispatch';
  END IF;
END;
$$;

-- Supabase Edge runtime secrets remain the source for the worker itself. Cron
-- reads the same bearer token from Vault so the token never enters the repo.
SELECT cron.schedule(
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
