# Live Dashboard UI Restoration Design

## Goal

Restore the accepted VOYA OS operations-dashboard experience on the protected `/workspace` route while replacing the preview-only values with tenant-scoped Supabase data. Preserve the existing authentication, MFA, membership, authorization, CRUD, RTL, and responsive behavior.

## Root Cause

The accepted dashboard implementation still exists in `OperationsDashboard`, but the hardened branch changed the public entry point to redirect into authentication and made the authenticated `/workspace` page render a temporary workspace placeholder. As a result, a successful user session never reaches the accepted dashboard UI. The sign-in page also grew a second authentication flow without preserving the original visual hierarchy, making the first-use surface taller and visually different.

## Design

### Protected workspace home

- Keep `/` as the authentication boundary: unauthenticated users are sent to `/sign-in`; authenticated users continue through `/workspace`.
- Keep all existing `loadWorkspaceContext` states and redirects unchanged: signed out, MFA required, pending access, organization selection, and ready membership.
- Replace only the `ready` workspace placeholder with the existing `OperationsDashboard` composition.
- Preserve the accepted dashboard anatomy: dark harbor sidebar, compact header, metric row, stay ribbon, arrivals table, approvals panel, Arabic RTL typography, current spacing/radii/shadows, and mobile navigation.
- Keep existing CRUD destinations under `/workspace/*`; the dashboard remains the command-center home and its navigation points to the existing live pages.

### Live data contract

- Add a focused server-side loader that receives the already-authorized organization membership and reads only through existing authenticated RPCs.
- Use `list_booking_work_queue` for tenant-scoped booking rows, `list_properties` for active property capacity, and `list_approval_requests` for role-filtered pending decisions.
- Derive honest dashboard metrics from those rows:
  - confirmed occupancy percentage for the current seven-day window, calculated from confirmed booked property-nights divided by active-property capacity;
  - arrivals whose check-in date is today;
  - pending approval requests visible to the current role.
- Map booking rows into the existing stay-ribbon and arrivals-table view models. Do not expose financial data, contact PII, raw database errors, or cross-tenant rows.
- Empty data must render an intentional empty state inside the existing dashboard regions, not fake preview records.
- Keep dates date-only and format them in `ar-EG`; use the existing LTR utility for codes and ISO/date ranges.
- Replace the preview-only notice with the same visual badge treatment and an explicit live-data label.

### Sign-in visual hierarchy

- Keep password sign-in and magic-link sign-in functionality and all server-side guards.
- Restore the original split-card proportions, copy density, and spacing rhythm.
- Make password sign-in the primary form and keep magic link as a compact fallback below the divider; avoid duplicated full-size email sections.
- Preserve disabled/unavailable feedback when environment configuration is missing and retain accessible labels, focus states, error announcements, and mobile no-overflow behavior.

## Component and data boundaries

- `src/features/dashboard/live-dashboard-data.ts`: pure view-model types, live-row mapping, date-window calculations, and the server loader contract.
- `src/features/dashboard/operations-dashboard.tsx`: remains the visual composition; receives a live-compatible `DashboardData` model and renders the same component families.
- `src/app/workspace/page.tsx`: remains responsible for auth state routing and supplies the ready membership to the dashboard loader.
- `src/app/sign-in/page.tsx` and auth form components: only adjust layout composition and visible copy; do not change authentication policy.

## Failure behavior

- Authentication and membership failures continue to use their current redirects.
- A Supabase read failure is surfaced through the existing workspace dependency/error boundary; no preview fallback is allowed in a live workspace.
- A valid empty result is rendered as an empty dashboard state with zero metrics.
- The dashboard loader must not broaden RPC permissions or bypass existing RLS/SECURITY DEFINER contracts.

## Verification

- Add unit coverage for seven-day occupancy calculation, date filtering, empty data, and live row mapping.
- Add workspace page coverage proving a ready authorized membership renders the dashboard while MFA/pending/selection states remain unchanged.
- Run the existing unit, lint, build, and relevant e2e suites.
- Run rendered QA in the Browser at desktop and a mobile viewport: verify page identity, non-blank content, no framework overlay, console health, mobile navigation, and at least one dashboard link interaction.
- Compare the rendered dashboard against the accepted `OperationsDashboard` anatomy using a mismatch ledger covering layout, palette, typography, spacing, RTL, responsive behavior, and live-data empty/populated states.
