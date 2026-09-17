-- Retire legacy magic-link rate-limit buckets before V1 narrows the allowed
-- auth rate-limit scopes. These rows are ephemeral throttling state, and the
-- V1 application no longer calls the magic_link scope.
--
-- This migration intentionally precedes 20260812014148_auth_rate_limit_v1_scopes.sql
-- so upgrades from pre-V1 production data cannot fail when the stricter CHECK
-- constraint is installed.

DELETE FROM public.auth_rate_limit_buckets
WHERE scope = 'magic_link';
