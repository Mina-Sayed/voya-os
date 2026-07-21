# Voya OS Foundation and Operations Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a production-minded, Arabic-first Voya OS walking skeleton: a responsive operations dashboard plus tested pure domain primitives for tenant identity, money formatting, booking date validation, and confirmed-booking conflict detection.

**Architecture:** The first slice is intentionally local and read-only at the UI boundary. It models trusted tenant context as a typed domain value and keeps booking rules in pure, tested functions so later Supabase adapters can enforce the same rules transactionally. The dashboard uses typed fixture data only; it does not claim authentication, database persistence, finance posting, approvals, or AI execution are implemented.

**Tech Stack:** Next.js 16 App Router, React 19, TypeScript 5, Tailwind CSS 4, Node test runner via Vitest, Lucide React icons, Playwright for responsive smoke coverage.

## Global Constraints

- Arabic is the default locale with `lang="ar"` and `dir="rtl"`; the dashboard must remain usable at 360px and desktop widths.
- Use `organizationId` in every domain fixture and domain signature. Do not trust UI-provided tenant values in future adapters.
- Booking date ranges are `[checkIn, checkOut)`; adjacent stays are valid and confirmed overlaps are invalid.
- Amounts are integer minor units. This slice only formats values and does not create financial records.
- No financial/audit delete, booking confirmation, approval, Supabase, OpenAI, service-role key, external notification, or live mutation implementation is in scope.
- Use accessible semantic landmarks, visible keyboard focus, localized labels, and reduced-motion-safe presentation.
- New production logic is test-first: run each named test red before implementation, then green; keep unit, integration-style UI, and security-review evidence.
- Keep the dashboard fixture-only and label it clearly as a preview until authenticated data access exists.

---

### Task 1: Test and package foundation

**Files:**

- Modify: `package.json`
- Create: `vitest.config.ts`
- Create: `src/test/setup.ts`
- Create: `src/test/smoke.test.ts`

**Interfaces:**

- Produces `npm run test`, `npm run test:watch`, and `npm run test:coverage` scripts.
- Produces a browser-like test environment for component tests and a Node-compatible domain-test environment.

- [x] **Step 1: Add a failing test-runner smoke test**

```ts
import { expect, test } from "vitest";

test("runs the Voya OS test suite", () => {
  expect(true).toBe(true);
});
```

- [x] **Step 2: Run the test to verify it fails because Vitest is not installed**

Run: `npm run test -- src/test/smoke.test.ts`

Expected: command failure stating that the `test` script or `vitest` command is unavailable.

- [x] **Step 3: Install test dependencies and add deterministic scripts/configuration**

```json
{
  "scripts": {
    "test": "vitest run",
    "test:watch": "vitest",
    "test:coverage": "vitest run --coverage"
  }
}
```

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["src/**/*.test.ts", "src/**/*.test.tsx"],
  },
});
```

- [x] **Step 4: Run the smoke test and full baseline checks**

Run: `npm run test -- src/test/smoke.test.ts && npm run lint && npm run build`

Expected: all commands exit 0.

### Task 2: Tenant and booking domain primitives

**Files:**

- Create: `src/domain/tenancy/organization.ts`
- Create: `src/domain/tenancy/organization.test.ts`
- Create: `src/domain/bookings/stay-range.ts`
- Create: `src/domain/bookings/stay-range.test.ts`
- Create: `src/domain/bookings/confirmed-booking.ts`
- Create: `src/domain/bookings/confirmed-booking.test.ts`

**Interfaces:**

- Produces `createOrganizationId(value: string): OrganizationId` and `isOrganizationId(value: string): boolean`.
- Produces `createStayRange(checkIn: string, checkOut: string): StayRange` and `stayRangesOverlap(left: StayRange, right: StayRange): boolean`.
- Produces `hasConfirmedBookingConflict(candidate: ConfirmedBooking, existing: readonly ConfirmedBooking[]): boolean`.

- [x] **Step 1: Write failing tenant-ID tests**

```ts
import { describe, expect, test } from "vitest";
import { createOrganizationId, isOrganizationId } from "./organization";

describe("organization identity", () => {
  test("accepts a non-empty UUID-shaped organization ID", () => {
    expect(createOrganizationId("4e3f2115-660a-42f5-9816-88d5b2f4cc8c")).toBe(
      "4e3f2115-660a-42f5-9816-88d5b2f4cc8c",
    );
  });

  test("rejects an empty organization ID", () => {
    expect(() => createOrganizationId(" ")).toThrow("Organization ID is required");
    expect(isOrganizationId(" ")).toBe(false);
  });
});
```

- [x] **Step 2: Run the tenant-ID test red**

Run: `npm run test -- src/domain/tenancy/organization.test.ts`

Expected: FAIL because the organization module does not exist.

- [x] **Step 3: Implement the minimal branded organization-ID module**

```ts
declare const organizationIdBrand: unique symbol;
export type OrganizationId = string & { readonly [organizationIdBrand]: true };

export function isOrganizationId(value: string): boolean {
  return value.trim().length > 0;
}

export function createOrganizationId(value: string): OrganizationId {
  if (!isOrganizationId(value)) throw new Error("Organization ID is required");
  return value as OrganizationId;
}
```

- [x] **Step 4: Write and run booking-range tests red**

```ts
test("allows adjacent stays and rejects overlapping confirmed stays", () => {
  const first = createStayRange("2026-08-01", "2026-08-04");
  const adjacent = createStayRange("2026-08-04", "2026-08-07");
  const overlap = createStayRange("2026-08-03", "2026-08-06");

  expect(stayRangesOverlap(first, adjacent)).toBe(false);
  expect(stayRangesOverlap(first, overlap)).toBe(true);
});
```

Run: `npm run test -- src/domain/bookings/stay-range.test.ts`

Expected: FAIL because the booking module does not exist.

- [x] **Step 5: Implement date-only range validation and conflict detection**

```ts
export type StayRange = Readonly<{ checkIn: string; checkOut: string }>;

export function stayRangesOverlap(left: StayRange, right: StayRange): boolean {
  return left.checkIn < right.checkOut && right.checkIn < left.checkOut;
}
```

Conflict detection must return `true` only when organization IDs and property IDs match, existing booking status is `confirmed`, and the half-open ranges overlap.

- [x] **Step 6: Run all domain tests green**

Run: `npm run test -- src/domain`

Expected: all tenant and booking tests pass.

### Task 3: Arabic-first visual system and fixture read model

**Files:**

- Modify: `src/app/layout.tsx`
- Modify: `src/app/globals.css`
- Create: `src/features/dashboard/dashboard-data.ts`
- Create: `src/features/dashboard/dashboard-data.test.ts`

**Interfaces:**

- Produces `dashboardData: DashboardData`, with an explicit fixture `organizationId` and no mutable financial/booking records.
- Produces semantic CSS tokens for `canvas`, `ink`, `muted`, `teal`, `aqua`, `sand`, and `danger`.

- [x] **Step 1: Write failing dashboard-data tenant tests**

```ts
import { expect, test } from "vitest";
import { dashboardData } from "./dashboard-data";

test("keeps all dashboard fixture records in the active organization", () => {
  const recordOrganizations = dashboardData.bookings.map((booking) => booking.organizationId);
  expect(new Set(recordOrganizations)).toEqual(new Set([dashboardData.organizationId]));
});
```

- [x] **Step 2: Run the fixture test red**

Run: `npm run test -- src/features/dashboard/dashboard-data.test.ts`

Expected: FAIL because the dashboard data module does not exist.

- [x] **Step 3: Implement the visual direction and fixture read model**

Use this reviewed design direction:

```text
Subject: an operations manager checking the pulse of furnished apartments before the morning handoff.
Palette: Night Harbor #112B32, Sea Glass #A9DDD0, Tide #1E7D78, Limestone #F5F2EA, Ink #102126, Signal Coral #D85E4D.
Type: Noto Kufi Arabic for display/body; Geist Mono for compact data labels.
Layout: right-side RTL navigation, a quiet top command bar, and a central calendar-like “stay ribbon” that connects arrivals, occupancy, and pending decisions.
Signature: the stay ribbon — a horizontal sequence of property stays with visible check-in/check-out edges, making the rental calendar the dashboard’s organizing device.
```

Set root `lang="ar"` and `dir="rtl"`, load Arabic-capable type, preserve a LTR utility class for dates/IDs, and include responsive/reduced-motion/focus styles.

- [x] **Step 4: Run fixture tests green**

Run: `npm run test -- src/features/dashboard/dashboard-data.test.ts`

Expected: PASS.

### Task 4: Responsive dashboard UI

**Files:**

- Modify: `src/app/page.tsx`
- Create: `src/features/dashboard/operations-dashboard.tsx`
- Create: `src/features/dashboard/operations-dashboard.test.tsx`

**Interfaces:**

- Produces `OperationsDashboard({ data }: { data: DashboardData }): React.ReactElement`.
- Displays Arabic labels for active organization, KPI summaries, stay ribbon, arrivals, pending approval actions, and a preview-data notice.

- [x] **Step 1: Write failing semantic UI tests**

```tsx
import { render, screen } from "@testing-library/react";
import { expect, test } from "vitest";
import { dashboardData } from "./dashboard-data";
import { OperationsDashboard } from "./operations-dashboard";

test("renders the Arabic operations heading and preview notice", () => {
  render(<OperationsDashboard data={dashboardData} />);
  expect(screen.getByRole("heading", { name: "صباحك منظّم" })).toBeInTheDocument();
  expect(screen.getByText("بيانات تجريبية للعرض فقط")).toBeInTheDocument();
});
```

- [x] **Step 2: Run the component test red**

Run: `npm run test -- src/features/dashboard/operations-dashboard.test.tsx`

Expected: FAIL because Testing Library and the dashboard component are not installed/implemented.

- [x] **Step 3: Install component-test dependencies and implement the dashboard**

Create semantic `header`, `nav`, `main`, `section`, `article`, `table`, and `button` structure. The page must use the fixture read model, show no destructive control, render the stay ribbon as a labeled list rather than an inaccessible graphic, and make any action button non-mutating with `type="button"`.

- [x] **Step 4: Run component tests green and lint**

Run: `npm run test -- src/features/dashboard/operations-dashboard.test.tsx && npm run lint`

Expected: PASS and exit 0.

### Task 5: Browser smoke, security, and documentation handoff

**Files:**

- Create: `playwright.config.ts`
- Create: `e2e/dashboard.spec.ts`
- Modify: `README.md`
- Modify: `docs/superpowers/plans/2026-07-21-foundation-dashboard.md`

**Interfaces:**

- Produces `npm run test:e2e` for a Chromium smoke test at 360px and 1440px.
- Documents exact implemented/simulated/not-implemented boundaries in the README.

- [x] **Step 1: Write the failing browser smoke specification**

```ts
import { expect, test } from "@playwright/test";

test("shows the Arabic operations dashboard at mobile and desktop widths", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "صباحك منظّم" })).toBeVisible();
  await expect(page.getByText("بيانات تجريبية للعرض فقط")).toBeVisible();
});
```

- [x] **Step 2: Run the browser test red**

Run: `npm run test:e2e -- e2e/dashboard.spec.ts`

Expected: FAIL because Playwright/configuration is not installed.

- [x] **Step 3: Add Playwright configuration and smoke coverage**

Configure a local `next dev` web server, Chromium projects for 360px and 1440px, and a deterministic base URL. Do not make the smoke test depend on network APIs or remote credentials.

- [x] **Step 4: Run final quality gates**

Run: `npm run test && npm run lint && npm run build && npm audit --omit=dev --audit-level=high`

Expected: unit tests, lint, and build exit 0. Audit must show no high/critical issue; any moderate inherited issue is documented with package/version and remediation decision.

- [x] **Step 5: Update README implementation status and mark plan steps accurately**

Document the commands, visible UI scope, non-implemented production controls, design system, test evidence, and the next implementation slice: Supabase Auth/membership/RLS integration.

## Plan self-review

- Coverage: this plan implements the recommended walking skeleton while preserving the PRD’s non-negotiable tenant, booking, financial, approval, audit, AI, RTL, and testing boundaries. It intentionally does not claim the complete application is built.
- Scope: all work is limited to a fixture-backed UI and pure domain rules; no unapproved finance or booking policy is invented.
- Type consistency: `OrganizationId`, `StayRange`, `ConfirmedBooking`, and `DashboardData` are defined before consumers. Component tests consume the same `DashboardData` fixture as the page.
- Ambiguity: dashboard actions remain explicitly non-mutating. PostgreSQL-level confirmed-booking enforcement remains a subsequent Supabase migration slice, not a promise from local TypeScript logic.
