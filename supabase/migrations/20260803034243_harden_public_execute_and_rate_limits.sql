-- Voya OS: deny anonymous execution of server-owned public RPCs.
-- The pre-auth limiter is the only public RPC intentionally callable by anon.

ALTER TABLE public.auth_rate_limit_buckets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.auth_rate_limit_buckets FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_auth_rate_limit(text, text, integer, integer) TO anon, authenticated;
;

