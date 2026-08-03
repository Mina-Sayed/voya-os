# Authentication Boundary Security Review

**Review date:** 2026-08-02
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
- Server-side Supabase SSR adapters use `tokens-only` cookie encoding and retrieve the user through `auth.getUser()`, preventing stale user-object cookie chunks from being trusted or combined across refreshes.
- `/workspace` resolves the authenticated user and active memberships on the server. Missing or suspended membership routes to the neutral access-pending outcome; multiple active memberships require an explicit, server-validated organization selection.
- A database-backed, hashed-email rate limiter runs before password or magic-link provider calls. It fails closed when the limiter dependency is unavailable and exposes only generic UI outcomes.
- The Next.js proxy applies a per-request nonce CSP, and the root layout is dynamic so framework scripts receive the nonce. Server Actions accept only the configured application origin.
- Sign-out is server-owned, clears the selected organization cookie, and redirects to the public sign-in screen even if the provider call fails.

## Verification evidence

- Unit tests cover complete/incomplete/production-HTTPS configuration, valid/invalid/provider-failed OTP requests, PKCE client configuration, and code/token-hash callback verification.
- Component tests cover Arabic labels, disabled configuration state, and sent-link feedback.
- Disposable local browser E2E verifies password sign-in, active/suspended/multi-membership behavior, session refresh, sign-out, request-time protected rendering, and the nonce-protected runtime. A real browser integration check also verified a generated token-hash link reaches the workspace.
- The focused database suite verifies anonymous/authenticated function grants, concurrent-safe rate-limit buckets, invalid-input rejection, and window expiry.

## Remaining release controls

1. Set `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, and `VOYA_APP_URL` separately per environment through Vercel/GitHub secrets/configuration; never commit them.
2. Configure the deployed Supabase Auth Site URL, `/auth/callback` redirect URL, PKCE email template, SMTP/provider limits, and password policy; verify the newest link in a clean browser after any provider/domain change.
3. Decide and implement the product's MFA/session-assurance and revocation policy; the repository does not invent that policy.
4. Run the authenticated managed Preview/production fixture and an authenticated Snyk scan before release. Local Snyk remains `BLOCKED` when its binary or credentials are absent.
