# Authentication Boundary Security Review

**Review date:** 2026-08-01
**Scope:** public Supabase configuration validation, server-only magic-link request, and Arabic sign-in route.

## Controls added

- Public configuration requires both the Supabase URL and publishable key; production URLs must be HTTPS.
- The service-role key is never read or referenced by this client/server authentication boundary.
- OTP submission runs through a Next server action and returns generic retry feedback, avoiding provider-error and account-enumeration detail.
- Redirect URLs are derived only from the configured `VOYA_APP_URL`, not browser form input or request headers.
- Platform-provisioned organizations are the launch assumption. The sign-in route has no organization, role, membership, booking, financial, audit, or approval mutation.
- Missing configuration disables the form and presents an explicit Arabic setup state.
- The callback accepts only a Supabase PKCE one-time `code` or a provider-issued `token_hash` with an allowlisted verification type; it never accepts a caller-chosen return path. Session cookies written during exchange/verification are retained on the fixed workspace redirect.
- Server-side Supabase clients explicitly use PKCE. An implicit-flow URL fragment is not parsed or logged by the server; deployment email templates must use the PKCE code or token-hash contract.
- `/workspace` resolves the authenticated user and exactly one active membership on the server. Missing, suspended, or ambiguous membership routes to the neutral access-pending outcome.

## Verification evidence

- Unit tests cover complete/incomplete/production-HTTPS configuration, valid/invalid/provider-failed OTP requests, PKCE client configuration, and code/token-hash callback verification.
- Component tests cover Arabic labels, disabled configuration state, and sent-link feedback.
- Disposable local browser E2E verifies password sign-in, active/suspended/multi-membership behavior, session refresh, and request-time protected rendering. A real browser integration check also verified a generated token-hash link reaches the workspace.

## Launch blockers

1. Add CSRF/origin/rate-limit controls suited to the deployment runtime and security telemetry with no email/OTP secret leakage.
2. Add session refresh/middleware, sign-out, MFA/session-assurance policy, and revocation tests.
3. Set `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, and `VOYA_APP_URL` separately per environment through Vercel/GitHub secrets/configuration; never commit them.
4. Configure the deployed Supabase Auth Site URL, additional `/auth/callback` redirect URL, and email template contract; verify the newest link in a clean browser after any provider/domain change.
