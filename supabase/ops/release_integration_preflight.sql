-- Run with the managed database owner's existing secure connection.
-- Inspection only: never creates a job, reads decrypted secrets or invokes a worker.
\set ON_ERROR_STOP on
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';

SELECT current_database() AS database_name, current_timestamp AS inspected_at;
SELECT version FROM supabase_migrations.schema_migrations ORDER BY version;
SELECT extname, extversion FROM pg_catalog.pg_extension
WHERE extname IN ('pg_cron', 'pg_net', 'supabase_vault');

SELECT name, count(*) AS configured_count FROM vault.secrets
WHERE name IN ('outbox_dispatch_url', 'outbox_worker_secret') GROUP BY name;
SELECT jobname, schedule, active FROM cron.job
WHERE jobname = 'voya-os-outbox-dispatch';
SELECT public.outbox_dispatch_scheduler_ready_v1() AS scheduler_ready;

SELECT id, public, file_size_limit, allowed_mime_types FROM storage.buckets
WHERE id IN ('property-images', 'ai-intake');

SELECT p.oid::regprocedure::text AS signature,
  p.prosecdef AS security_definer,
  (SELECT setting FROM unnest(p.proconfig) setting
    WHERE setting LIKE 'search_path=%' LIMIT 1) AS function_search_path,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS staff_execute,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_execute,
  has_function_privilege('voya_outbox_worker', p.oid, 'EXECUTE') AS worker_execute
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND (
  p.proname IN ('claim_whatsapp_property_confirmation_v1',
    'create_commercial_booking_draft', 'confirm_commercial_booking',
    'confirm_booking', 'update_lead_v1', 'apply_whatsapp_ai_result_v1',
    'store_whatsapp_media_v1', 'fail_whatsapp_media_event_v1',
    'fail_whatsapp_ai_outbox_event_v1', 'reconcile_outbox_dispatch_scheduler_v1')
  OR p.proname LIKE '%without_workspace_aal2%'
  OR p.proname = 'list_clients_v1_before_release_integration'
) ORDER BY signature;

SELECT p.oid::regprocedure::text AS unexpected_public_execute
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
WHERE n.nspname = 'public' AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'
ORDER BY unexpected_public_execute;

SELECT relname AS tenant_table_without_forced_rls
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
  AND EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = c.oid AND a.attname = 'organization_id' AND NOT a.attisdropped)
  AND (NOT c.relrowsecurity OR NOT c.relforcerowsecurity);
ROLLBACK;
