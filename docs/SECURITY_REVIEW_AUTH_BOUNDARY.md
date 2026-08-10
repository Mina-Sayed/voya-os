# Authentication Boundary Security Review

**Review date:** 2026-08-10
**Scope:** public Supabase configuration validation, server-only magic-link request, and Arabic sign-in route.

## Controls added

- Public configuration requires both the Supabase URL and publishable key; production URLs must be HTTPS.
- The service-role key is read only by server-side rate-limit helpers and local isolated test-server setup; it is never imported by client components or exposed through `NEXT_PUBLIC_*` values.
- OTP submission runs through a Next server action and returns generic retry feedback, avoiding provider-error and account-enumeration detail.
- Redirect URLs are derived only from the configured `VOYA_APP_URL`, not browser form input or request headers.
- Callback and password sign-in distinguish active, suspended, and missing memberships. Suspended users reach only the neutral access-pending outcome; personal workspace bootstrap is limited to a verified email with no existing membership.
- Workspace routes require Supabase MFA assurance level AAL2. The browser challenge uses only the publishable client and verified TOTP factor; service credentials remain server-only.
- The custom database auth limiter has a fixed database-owned policy and is executable only by the service role. Supabase native Auth rate limits and CAPTCHA remain required defense-in-depth for public endpoints.
- Missing configuration disables the form and presents an explicit Arabic setup state.
- The callback accepts only a Supabase one-time `code`; it never accepts a caller-chosen return path. Session cookies written during exchange are retained on the fixed workspace redirect.
- `/workspace` resolves the authenticated user and exactly one active membership on the server. Missing, suspended, or ambiguous membership routes to the neutral access-pending outcome.

## Verification evidence

- Unit tests cover complete/incomplete/production-HTTPS configuration and valid/invalid/provider-failed OTP requests.
- Component tests cover Arabic labels, disabled configuration state, and sent-link feedback.
- Browser E2E verifies the public-to-sign-in boundary, protected-route redirects, neutral access-pending page, and the isolated authenticated workspace at desktop and mobile widths. Visual review was completed at 360px and desktop widths.

## Launch blockers

1. Add security telemetry with no email/OTP secret leakage and monitor Supabase Auth native rate-limit/CAPTCHA events alongside the server-side limiter.
2. Add explicit sign-out and MFA-factor revocation tests for the production identity-provider configuration.
3. Set `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `VOYA_APP_URL`, and server-only `SUPABASE_SERVICE_ROLE_KEY` separately per environment through Vercel/GitHub secrets/configuration; never commit them or expose the service key to the browser.
