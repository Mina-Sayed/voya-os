# Live Dashboard UI Restoration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task with verification checkpoints.

**Goal:** Restore the accepted VOYA OS dashboard UI at `/workspace` and feed it tenant-scoped live Supabase data without weakening authentication or authorization.

**Architecture:** Keep `loadWorkspaceContext` as the protected route boundary. Add a focused dashboard data adapter that calls existing authenticated RPCs in parallel, maps database rows to the existing `DashboardData` view model, and leaves `OperationsDashboard` responsible for presentation. Keep the accepted dashboard shell and make the sign-in surface compact while preserving both auth methods.

**Tech Stack:** Next.js App Router, React, TypeScript, Tailwind CSS v4, Supabase SSR/RPC, Vitest, Testing Library, Playwright/browser QA.

## Global Constraints

- Preserve the existing signed-out, MFA-required, pending, organization-selection, and active-membership states.
- All live reads must use existing authenticated tenant-scoped RPCs; do not add broad table reads or service-role access to the dashboard.
- Do not expose finance, contact PII, raw database errors, or cross-tenant rows.
- Preserve the accepted Arabic RTL dashboard anatomy, palette, typography, spacing, responsive mobile navigation, and existing CRUD links.
- No preview fallback is allowed for a ready live workspace; empty Supabase results render honest zero/empty states.
- Every production-code change gets a failing regression test first and a fresh verification run before completion.

---

### Task 1: Define and test live dashboard mapping

**Files:**
- Create: `src/features/dashboard/live-dashboard-data.test.ts`
- Create: `src/features/dashboard/live-dashboard-data.ts`
- Modify: `src/features/dashboard/dashboard-data.ts`

**Interfaces:**
- `LiveDashboardInputs`: booking work-queue rows, active-property count, approval rows, current date, and organization metadata.
- `buildDashboardData(inputs: LiveDashboardInputs): DashboardData` returns the existing dashboard view model with `isPreview: false`.
- `loadLiveDashboardData(client, membership): Promise<DashboardData>` calls `list_booking_work_queue`, `list_properties`, and `list_approval_requests` in parallel.

- [ ] **Step 1: Write the failing tests.** Cover confirmed booked property-nights divided by active-property capacity for the next seven date keys, today-arrival filtering, pending-only approvals, empty data, and database-to-view-model mapping.

```ts
it("builds live metrics and filters today arrivals from tenant-scoped rows", () => {
  const data = buildDashboardData({
    organizationId: "org-qa" as OrganizationId,
    organizationName: "فُويا QA",
    operatorName: "مشغل QA",
    today: "2026-08-11",
    activePropertyCount: 2,
    bookings: [
      { id: "b1", propertyCode: "A-1", propertyName: "النيل", clientName: "عميل 1", status: "confirmed", checkIn: "2026-08-11", checkOut: "2026-08-13", hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-10T10:00:00Z" },
      { id: "b2", propertyCode: "A-2", propertyName: "المعادي", clientName: "عميل 2", status: "pending_approval", checkIn: "2026-08-12", checkOut: "2026-08-14", hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-10T09:00:00Z" },
    ],
    approvals: [{ id: "a1", resourceType: "booking", proposedAction: "booking.confirm", status: "pending", expiresAt: null, createdAt: "2026-08-11T09:00:00Z" }],
  });

  expect(data.metrics.map((metric) => metric.value)).toEqual(["14٪", "1", "1"]);
  expect(data.bookings.map((booking) => booking.id)).toEqual(["b1", "b2"]);
  expect(data.approvals).toHaveLength(1);
});
```

- [ ] **Step 2: Run the focused test to verify RED.**

Run: `npm run test -- src/features/dashboard/live-dashboard-data.test.ts`

Expected: FAIL because the live mapping module and builder do not exist.

- [ ] **Step 3: Implement the smallest pure mapper.** Keep date-only arithmetic in named helpers, use `Math.round`, clamp occupancy to `0..100`, map live statuses to the accepted Arabic labels, and use zero/empty values when inputs are empty.

- [ ] **Step 4: Run the focused test to verify GREEN.**

Run: `npm run test -- src/features/dashboard/live-dashboard-data.test.ts`

Expected: PASS with all mapping and empty-state assertions green.

- [ ] **Step 5: Add the authenticated loader.** Call the three existing RPCs with `p_organization_id: membership.organizationId` using `Promise.all`; throw RPC errors unchanged so the current workspace error boundary handles them. Do not query using a service-role client.

- [ ] **Step 6: Run the focused test and typecheck.**

Run: `npm run test -- src/features/dashboard/live-dashboard-data.test.ts && npx tsc --noEmit`

Expected: PASS.

- [ ] **Step 7: Commit the data adapter.**

```bash
git add src/features/dashboard/dashboard-data.ts src/features/dashboard/live-dashboard-data.ts src/features/dashboard/live-dashboard-data.test.ts
git commit -m "feat: map live workspace data to dashboard view"
```

### Task 2: Render the live dashboard through the protected workspace route

**Files:**
- Modify: `src/app/workspace/page.tsx`
- Modify: `src/features/dashboard/operations-dashboard.tsx`
- Modify: `src/features/dashboard/operations-dashboard.test.tsx`
- Create or modify: `src/app/workspace/page.test.tsx`
- Modify: `e2e/authenticated-workspace.spec.ts`

**Interfaces:**
- The ready branch of `WorkspacePage` calls `loadLiveDashboardData` with the authorized membership and renders `<OperationsDashboard data={data} />`.
- Selection and all redirect states remain unchanged.

- [ ] **Step 1: Write the failing route test.** Assert that a ready membership renders the original `صباحك منظّم` heading and live-data badge; keep existing tests for MFA, pending, and organization selection unchanged.

- [ ] **Step 2: Run the route/dashboard tests to verify RED.**

Run: `npm run test -- src/app/workspace/page.test.tsx src/features/dashboard/operations-dashboard.test.tsx`

Expected: FAIL because the ready route still renders `مساحة عمل محمية` instead of the dashboard.

- [ ] **Step 3: Replace only the ready placeholder.** Keep the existing auth state branches and use the new loader for the ready membership. Update `DashboardData` from preview-only to live-compatible without changing the dashboard’s layout primitives.

- [ ] **Step 4: Add honest live badge and empty-state copy without changing component geometry.** The same pill, metric cards, stay-ribbon, arrivals section, and approval panel stay in place; empty arrays render a concise empty message rather than demo records.

- [ ] **Step 5: Run the focused route/dashboard tests to verify GREEN.**

Run: `npm run test -- src/app/workspace/page.test.tsx src/features/dashboard/operations-dashboard.test.tsx`

Expected: PASS.

- [ ] **Step 6: Update the authenticated E2E expectation.** The single-membership workspace test must assert `صباحك منظّم`, while MFA, membership selection, forged-cookie rejection, suspended access, and private-cache assertions remain intact.

- [ ] **Step 7: Commit the protected home.**

```bash
git add src/app/workspace/page.tsx src/app/workspace/page.test.tsx src/features/dashboard/dashboard-data.ts src/features/dashboard/operations-dashboard.tsx src/features/dashboard/operations-dashboard.test.tsx e2e/authenticated-workspace.spec.ts
git commit -m "feat: restore live operations dashboard home"
```

### Task 3: Restore the compact sign-in visual hierarchy

**Files:**
- Modify: `src/app/sign-in/page.tsx`
- Modify: `src/features/auth/password-sign-in-form.tsx`
- Modify: `src/features/auth/sign-in-form.tsx`
- Modify: `src/features/auth/sign-in-form.test.tsx`
- Modify: `src/features/auth/password-sign-in-form.test.tsx`
- Modify: `e2e/dashboard.spec.ts`

**Interfaces:**
- Password sign-in remains the primary action and magic link remains the fallback action.
- Existing action signatures, status values, accessibility labels, and disabled configuration behavior remain unchanged.

- [ ] **Step 1: Write the failing visual-structure assertions.** Assert one primary email field in the password section, a compact magic-link section below the divider, the original hero copy, and no horizontal overflow at 390px.

- [ ] **Step 2: Run the focused sign-in tests to verify RED.**

Run: `npm run test -- src/features/auth/sign-in-form.test.tsx src/features/auth/password-sign-in-form.test.tsx`

Expected: FAIL on the current duplicated full-size form structure or updated copy.

- [ ] **Step 3: Implement the minimal layout correction.** Preserve the split card and original spacing; keep password inputs in the existing visual form region, make the magic-link form compact, and retain all error/cooldown states.

- [ ] **Step 4: Run focused sign-in tests and the public E2E smoke tests.**

Run: `npm run test -- src/features/auth/sign-in-form.test.tsx src/features/auth/password-sign-in-form.test.tsx && npx playwright test e2e/dashboard.spec.ts`

Expected: PASS with no mobile horizontal overflow.

- [ ] **Step 5: Commit the auth-surface restoration.**

```bash
git add src/app/sign-in/page.tsx src/features/auth/password-sign-in-form.tsx src/features/auth/sign-in-form.tsx src/features/auth/sign-in-form.test.tsx src/features/auth/password-sign-in-form.test.tsx e2e/dashboard.spec.ts
git commit -m "fix: restore compact sign-in visual hierarchy"
```

### Task 4: Rendered visual QA and full verification

**Files:**
- No committed files by default; screenshots and traces stay outside the repository.

- [ ] **Step 1: Run the full quality gate.**

Run: `npm run test && npm run lint && npm run build`

Expected: all unit tests, lint, and production build pass.

- [ ] **Step 2: Start the app using the repository’s existing dev command and use Browser validation.** Verify `/sign-in` when signed out and `/workspace` through the disposable authenticated flow when available.

- [ ] **Step 3: Check desktop and mobile rendering.** Capture the dashboard at a desktop viewport and a 390px mobile viewport; confirm no clipping, overflow, broken RTL ordering, missing icons, or framework overlay.

- [ ] **Step 4: Exercise one real interaction.** Open mobile navigation and activate the properties or clients link; verify URL and rendered page identity.

- [ ] **Step 5: Record a mismatch ledger.** Compare shell, palette, typography, spacing, cards/table, live empty/populated states, responsive behavior, and auth hierarchy against the accepted dashboard component.

- [ ] **Step 6: Commit only after fresh verification.**

```bash
git status --short --branch
git log --oneline -5
```

Expected: only the intended commits/files are present and all verification commands have fresh passing output.
