-- The production readiness endpoint uses a server-only service-role read to
-- verify Postgres reachability. Keep this privilege narrow; browser roles
-- continue to use the existing membership-scoped policy.
GRANT SELECT ON TABLE public.organizations TO service_role;
