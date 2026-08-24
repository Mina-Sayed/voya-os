-- Test-only shim for the Supabase Auth objects referenced by the migration.
-- This file must only be applied to an ephemeral PostgreSQL test database.
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY,
  email text
);

ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS email text;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS email_confirmed_at timestamptz;

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

CREATE OR REPLACE FUNCTION auth.email()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.email', true), '');
$$;

-- PostgREST exposes the full JWT to Supabase through request.jwt.claims. Most
-- historical SQL fixtures predate MFA and set only the individual claim GUCs,
-- so treat those workspace fixtures as AAL2 unless a test explicitly supplies
-- an assurance level. Explicit full claims remain authoritative and therefore
-- allow regression tests to model aal1 denial accurately.
CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    NULLIF(current_setting('request.jwt.claims', true), '')::jsonb,
    jsonb_build_object(
      'sub', NULLIF(current_setting('request.jwt.claim.sub', true), ''),
      'email', NULLIF(current_setting('request.jwt.claim.email', true), ''),
      'aal', coalesce(NULLIF(current_setting('request.jwt.claim.aal', true), ''), 'aal2')
    )
  );
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END;
$$;
