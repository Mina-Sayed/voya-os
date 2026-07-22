# Lead Registry Safe Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tenant-isolated, audited, safe operational lead registry and Arabic-first workspace without unapproved contact or financial data.

**Architecture:** PostgreSQL owns lead tenancy, assignment, authorization, idempotency, audit, and outbox side effects. The Next.js server action injects trusted membership context; direct browser table access remains revoked.

**Tech Stack:** Supabase PostgreSQL, Next.js 16, TypeScript, Tailwind CSS, Vitest, Playwright.

## Global Constraints

- Only title, source, lifecycle status, optional requested half-open range, and optional same-tenant assignee are stored.
- PII, consent, notes, budget, conversion, merge, status changes, external messaging, and booking/financial mutations are excluded.
- Owner/manager/sales_agent create; owner/manager list all; sales_agent lists self-assigned/unassigned; all other roles fail closed.
- A successful command writes audit and outbox records in its transaction.
- Do not stage existing uncommitted user work.

---

### Task 1: Database command and authorization boundary

**Files:**
- Create: `supabase/migrations/20260722001800_lead_registry_commands.sql`
- Create: `supabase/tests/lead_registry_command_read.sql`
- Modify: `scripts/test-database-foundation.mjs`

**Interfaces:** Produces `create_lead(uuid,text,text,text,date,date,uuid,text,uuid)` and `list_leads(uuid)`.

- [ ] **Step 1: Write failing SQL assertions**

```sql
SELECT public.create_lead('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'إقامة صيفية', 'website', 'new', DATE '2027-06-01', DATE '2027-06-05', NULL, 'lead-request-1');
```

Assert idempotent replay, same-tenant assignment, cross-tenant rejection, invalid range/status rejection, sales list scope, role denial, audit, and outbox.

- [ ] **Step 2: Run database tests red**

Run: `VOYA_DB_TEST=1 DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/voya_test npm run test:db`

Expected: FAIL because `create_lead` does not exist.

- [ ] **Step 3: Implement migration and runner entry**

Create `leads` with tenant-qualified assignee FK, status/range checks, tenant idempotency uniqueness, indexes, forced RLS, direct-grant denial, and the two security-definer RPCs. Insert `lead.created` audit/outbox records in `create_lead`.

- [ ] **Step 4: Run database tests green**

Run: `VOYA_DB_TEST=1 DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/voya_test npm run test:db`

Expected: PASS including lead-registry evidence.

### Task 2: Arabic-first workspace and trusted server action

**Files:**
- Create: `src/features/leads/leads-page.tsx`
- Create: `src/features/leads/lead-create-form.tsx`
- Create: `src/features/leads/leads-page.test.tsx`
- Create: `src/features/leads/lead-create-form.test.tsx`
- Create: `src/app/workspace/leads/page.tsx`
- Create: `src/app/workspace/leads/actions.ts`
- Modify: `e2e/access-pending.spec.ts`

**Interfaces:** Produces `LeadsPage`, `LeadCreateForm`, and `createLeadAction` over the two RPCs.

- [ ] **Step 1: Write failing UI tests**

```tsx
render(<LeadsPage leads={[]} createLead={action} />);
expect(screen.getByRole("heading", { name: "العملاء المحتملون" })).toBeInTheDocument();
expect(screen.getByLabelText("عنوان الطلب")).toBeRequired();
```

- [ ] **Step 2: Run focused tests red**

Run: `npm test -- src/features/leads/leads-page.test.tsx src/features/leads/lead-create-form.test.tsx`

Expected: FAIL because modules do not exist.

- [ ] **Step 3: Implement minimum interface**

Render Arabic title/source/optional dates input only, explicitly state that contact data, pricing, and reservation are absent. The action validates input, resolves active membership, calls RPC with request ID, maps safe errors, and revalidates only after success.

- [ ] **Step 4: Verify unit and route protection**

Run: `npm test -- src/features/leads/leads-page.test.tsx src/features/leads/lead-create-form.test.tsx && npm run test:e2e`

Expected: PASS.

### Task 3: Security review and verification

**Files:**
- Create: `docs/SECURITY_REVIEW_LEAD_REGISTRY_FOUNDATION.md`

- [ ] **Step 1: Document tenant/role/PII boundaries and residual PII/conversion risks.**
- [ ] **Step 2: Run `npm run test:coverage`, local `npm run test:db`, `npm run test:e2e`, `npm run lint`, `npm run build`, `npm audit --omit=dev --audit-level=high`, and `git diff --check`.**
- [ ] **Step 3: Commit only files owned by this plan.**
