-- The worker is invoked by Supabase Cron and authenticates with a Vault-held
-- bearer token. Keep the extensions consistent across staging and production.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS supabase_vault WITH SCHEMA vault;
