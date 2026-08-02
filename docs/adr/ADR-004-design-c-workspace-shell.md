# ADR-004: Design C shared workspace shell

## Status

Accepted for the first live workspace slice.

## Context

The repository had a fixture dashboard and independent pages that repeated headers, navigation, status language, and spacing. This made tenant context difficult to perceive and caused each route to drift visually. The product direction requires a live Arabic RTL workspace with equivalent mobile navigation.

## Decision

Introduce one server-composed `WorkspaceShell` that receives the server-resolved organization name, role, active route, and page content. The shell owns persistent navigation, organization context, role copy, mobile entry, and unavailable-module states. Feature pages keep their own data forms and domain boundaries but render inside the shared shell.

The live dashboard uses only existing tenant-scoped read RPCs. Calls are selected by role capability; a role that cannot read leads or approvals receives an empty state rather than a client-side bypass or fabricated fixture row.

## Consequences

- Navigation and context are consistent across all protected routes.
- The public `/` entry no longer exposes operational fixture data; it redirects to the protected workspace.
- Existing feature pages can be migrated incrementally without changing their command contracts.
- New CRM, WhatsApp, AI, finance, and self-service screens must add a server read model and a capability entry before becoming actionable.

## Verification

- `npm test` covers the shell, live-dashboard mapping, and existing feature contracts.
- `npm run test:e2e` covers protected public entry and mobile sign-in overflow.
- `VOYA_AUTH_E2E_DISPOSABLE=1 npm run test:e2e:auth-local` covers live single/multi-membership workspace access and role-safe dashboard loading.
