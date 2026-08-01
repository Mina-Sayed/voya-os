# Security Review: Server-Owned Password Sign-In

Date: 2026-08-01
Scope: Slice 1 existing/provisioned Voya memberships; magic-link sign-in remains available.

## Boundary and controls

- The browser submits credentials to a Next.js Server Action. It does not create a Supabase client session or write identity, membership, organization, or profile rows directly.
- `createServerPasswordGateway` uses the existing Supabase SSR cookie adapter, so session and refresh cookies are written only in the server-owned action boundary.
- The pure auth contract normalizes the email, validates required input, and returns only stable statuses. Passwords, provider messages, tokens, and membership details are never returned to the client.
- Provider status `400` becomes generic invalid credentials and `429` becomes a rate-limit message. Other failures become a generic retry result; configuration failures become unavailable.
- Missing or invalid Supabase public configuration fails closed to `/sign-in` for protected pages instead of rendering a dependency exception; the structured operational log retains only a safe code and request ID.
- A successful session is not authorization. The protected workspace context still derives active memberships, requires organization selection for multiple memberships, and fails closed for forged, suspended, or stale selections.
- No public organization bootstrap, role assignment, or self-service membership creation is introduced in this slice.

## Reproduction and evidence

Run the pure and action regression tests:

```bash
npm test -- src/features/auth/password-sign-in.test.ts src/app/sign-in/actions.test.ts
npm test -- src/features/auth/password-sign-in-form.test.tsx
VOYA_AUTH_E2E_DISPOSABLE=1 npm run test:e2e:auth-local
```

The regression suite covers normalized credentials, invalid credentials, provider rate limiting, missing configuration, generic UI feedback, pending-submit locking, and a real local Supabase browser session. The authenticated browser suite also proves membership selection and denial boundaries after login.

The pre-implementation red tests were the missing password contract/action/component modules. They now pass without exposing a secret in the result or rendered feedback.

## Residual risks and rollback

- Supabase email-confirmation, provider rate limits, and local SMTP behavior remain environment/provider configuration dependencies; production values must be verified separately.
- Public self-service registration and private organization bootstrap remain deferred to Slice 6 and require abuse controls, verification, and an explicit product/security review.
- If password sign-in must be disabled, hide or feature-flag the password form while retaining the existing magic-link path; no schema rollback is required.

No Critical or High defect was found in this slice's server-owned password boundary. Final release approval still depends on the repository-wide integration, scanner, and production checks recorded in `docs/TEST_PLAN.md`.
