# Release Readiness Completion Design

**Date:** 2026-07-26
**Status:** Approved

## Scope

Complete the production-reliability plan without inventing unresolved product or financial policy. This slice addresses the remaining verified gaps after the authentication, tenant-context, idempotency, logging, and outbox remediation:

- misleading enabled controls on the public demonstration dashboard;
- missing mobile navigation for the dashboard's existing destinations;
- an invalid settings anchor;
- the default English 404 inside an Arabic-first product;
- callback redirects that must use a trusted application origin in production;
- the missing authenticated local session-refresh and multi-organization browser fixture;
- low-value coverage gaps in the changed reliability boundary;
- the vulnerable PostCSS copy nested under Next.js;
- locally reproducible security scanning and explicit reporting for tools that require external credentials.

Deployment, managed Supabase mutation, production credentials, notification delivery, and unresolved finance, approval, retry, retention, or provider policy remain outside this slice.

## Options considered

1. **Implement every visible dashboard control.** Rejected because notifications, account management, approvals, and operational actions require product and authorization rules that are not approved.
2. **Remove every incomplete control.** Safe but hides the intended information architecture and makes the demonstration less useful.
3. **Represent incomplete behavior honestly while completing existing navigation and release gates (selected).** Keep the visual affordances only as clearly disabled “coming soon” states, implement navigation only to routes that already exist, and complete deterministic reliability evidence.

## User interface behavior

The dashboard remains explicitly demonstrational. Controls without implemented behavior are rendered as disabled controls with a visible Arabic “قريبًا” explanation and no hover styling that implies activation:

- notifications;
- operator/account menu;
- arrival options;
- approval-list action;
- settings.

No fake modal, notification list, account action, approval execution, or settings form is introduced.

Existing destinations—overview, bookings, properties, and clients—are available through an accessible mobile navigation control. The control supports keyboard activation, exposes its expanded state, closes after navigation or Escape, traps no focus when closed, and does not reveal protected data. Protected destinations continue to redirect unauthenticated users to sign-in.

Add an Arabic `not-found` page with a clear return link. It must preserve the current security headers and disclose no route or tenant details.

## Trusted callback origin

Authentication callback redirects remain restricted to the fixed internal paths `/workspace` and `/access-pending`. In production, the absolute redirect origin comes only from a validated `VOYA_APP_URL`:

- the value must parse as an absolute URL;
- production requires HTTPS;
- credentials, fragments, and non-root path prefixes are rejected;
- browser query parameters and forwarded host headers never choose the destination.

Local development may fall back to the request origin so `127.0.0.1` and `localhost` behave naturally. Invalid or absent production configuration fails closed to `/access-pending` using a sanitized operational event; it must not create an open redirect.

## Authenticated local fixture

Use an isolated local Supabase-compatible stack and synthetic data only. The fixture creates:

- one synthetic user with one active membership;
- one synthetic user with two active memberships;
- a suspended membership and a foreign organization for negative checks.

Browser tests sign in through a test-only server-owned fixture path that is unavailable outside the test environment. The path must not accept arbitrary user, organization, role, redirect, or token material from the browser. It issues only fixture identities defined in test code and is excluded or returns not found unless an explicit test guard is present.

Acceptance coverage:

- a valid session reaches the tenant-scoped workspace;
- an expired access token refreshes without producing a shared-cache response;
- a single membership is selected automatically;
- several memberships require explicit selection;
- forged, stale, foreign, and suspended organization selections fail closed;
- unauthenticated behavior remains unchanged.

If the current local Supabase tooling cannot provide real refresh semantics without adding a production-like secret to the repository, keep the fixture external to Git and report the exact remaining gate rather than weakening the boundary.

## Coverage strategy

Raise meaningful coverage for the changed reliability boundary rather than adding assertion-free lines. Priority targets are:

- workspace-context state transitions and loader error classification;
- server-auth cookie behavior;
- proxy returned/thrown/configuration failures;
- callback redirect-origin validation and sanitized failure stages;
- dashboard navigation, disabled states, keyboard behavior, and mobile layout;
- Arabic 404 behavior.

The repository-wide goal remains greater than 90% where meaningful. This slice is accepted only when the changed modules exceed 90% statements and branches or each uncovered branch has a documented environment-only reason. Repository-wide coverage below 90% remains a reported gate rather than being hidden.

## Supply-chain and scanners

Do not run `npm audit fix --force` and do not downgrade Next.js.

Resolve the nested PostCSS advisory in this order:

1. Prefer a stable supported Next.js release whose own dependency graph contains a patched PostCSS.
2. If no stable release exists, evaluate an npm override to a patched compatible PostCSS using Next's current documentation, lockfile inspection, full build, production smoke, browser tests, and CSS output inspection.
3. If compatibility cannot be demonstrated, retain the advisory as an explicit release blocker instead of forcing an unsafe dependency graph.

Run Trivy locally through a pinned container or an already-installed binary, scanning the repository filesystem/configuration/secrets without uploading source. Snyk runs only when an existing authenticated installation is available; no account creation, token acquisition, or source upload is inferred from this task. Add deterministic local secret/dependency checks that do not depend on Snyk so absence of that external service does not imply a clean scan.

## Error handling and observability

- Expected disabled controls do not emit operational failures.
- Mobile navigation errors are client-visible only when an actual navigation fails.
- Callback configuration errors use fixed safe codes and generated request IDs.
- Test fixture failures contain no tokens, cookies, emails, raw database messages, or credentials.
- Missing local auth configuration remains distinguishable from provider failure without flooding production alerts.

## Verification

Use red-green-refactor for each behavior change. Required evidence:

1. Focused unit/component tests for disabled controls, mobile navigation, Arabic 404, and trusted callback origin.
2. Authenticated local integration/browser tests when the isolated fixture is available.
3. `npm run test:coverage`, `npm run lint`, and `npm run build`.
4. Production rendering/cache smoke and full Chromium E2E.
5. Fresh PostgreSQL 17 database suite, including outbox timezone, drift, and concurrent claim tests.
6. `npm audit --omit=dev --audit-level=high`.
7. Trivy filesystem/config/secret scan; Snyk only when already authenticated and available.
8. Manual desktop/mobile RTL browser QA, keyboard navigation, viewport-fit measurements, screenshots, console, and network-error inspection.
9. Independent read-only security review of authentication, redirects, fixture isolation, tenant selection, dependency changes, and logs.
10. `git diff --check` and confirmation that unrelated dirty-tree changes remain untouched.

## Rollout and rollback

Application and dependency changes go to an isolated Preview environment first. Validate the real deployment origin, callback redirect, token refresh, mobile navigation, cache headers, and scanner artifact before production approval.

Rollback uses the previous immutable application deployment. Database history is not rewritten. Test-only fixture routes never ship enabled. A dependency override, if selected, is removed by reverting its declarative package and lockfile changes after moving to a stable patched Next release.

## Completion boundary

This slice can establish code correctness and local release evidence. It cannot by itself authorize production deployment, managed database migration, external Snyk access, or approval of unresolved product policy. Any unavailable external gate remains explicitly `BLOCKED`; it is never converted to `PASS`.
