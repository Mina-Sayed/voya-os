# Authentication Boundary Security Review

**Review date:** 2026-07-21
**Scope:** public Supabase configuration validation, server-only magic-link request, and Arabic sign-in route.

## Controls added

- Public configuration requires both the Supabase URL and publishable key; production URLs must be HTTPS.
- The service-role key is never read or referenced by this client/server authentication boundary.
- OTP submission runs through a Next server action and returns generic retry feedback, avoiding provider-error and account-enumeration detail.
- Redirect URLs are derived only from the configured `VOYA_APP_URL`, not browser form input or request headers.
- Platform-provisioned organizations are the launch assumption. The sign-in route has no organization, role, membership, booking, financial, audit, or approval mutation.
- Missing configuration disables the form and presents an explicit Arabic setup state.

## Verification evidence

- Unit tests cover complete/incomplete/production-HTTPS configuration and valid/invalid/provider-failed OTP requests.
- Component tests cover Arabic labels, disabled configuration state, and sent-link feedback.
- Browser E2E verifies the unavailable route at desktop and mobile widths. Visual review was completed at 360px and desktop widths.

## Launch blockers

1. Add `/auth/callback` with PKCE code exchange, exact return-path allowlisting, and secure cookie update behavior.
2. After callback, resolve an active membership server-side and redirect users without membership to a non-enumerating access-pending screen. Do not infer `organization_id` from a cookie, URL, or model output.
3. Add CSRF/origin/rate-limit controls suited to the deployment runtime and security telemetry with no email/OTP secret leakage.
4. Add session refresh/middleware, sign-out, MFA/session-assurance policy, and revocation tests.
5. Set `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, and `VOYA_APP_URL` separately per environment through Vercel/GitHub secrets/configuration; never commit them.
