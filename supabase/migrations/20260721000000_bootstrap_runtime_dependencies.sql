-- Fresh-restore dependency bootstrap. This intentionally sorts before every
-- migration that references extensions.pgcrypto or voya_outbox_worker.
-- The forward hardening migration repeats these idempotent operations so an
-- already-migrated environment remains safe even before this file is recorded.

CREATE SCHEMA IF NOT EXISTS extensions;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_extension AS extension
    JOIN pg_namespace AS namespace ON namespace.oid = extension.extnamespace
    WHERE extension.extname = 'pgcrypto'
      AND namespace.nspname <> 'extensions'
  ) THEN
    EXECUTE 'ALTER EXTENSION pgcrypto SET SCHEMA extensions';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'voya_outbox_worker') THEN
    CREATE ROLE voya_outbox_worker NOLOGIN;
  END IF;
END;
$$;
