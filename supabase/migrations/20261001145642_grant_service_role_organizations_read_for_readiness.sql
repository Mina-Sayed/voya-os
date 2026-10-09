-- Production readiness probes organization-table reachability with a bounded
-- id-only SELECT through service_role. Keep the grant read-only and table-local.
GRANT SELECT ON TABLE public.organizations TO service_role;
