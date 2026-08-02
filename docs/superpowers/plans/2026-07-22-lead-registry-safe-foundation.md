# Lead Registry Safe Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tenant-isolated, audited lead registry and Arabic-first workspace without unapproved contact or financial data.

**Architecture:** PostgreSQL owns lead state, authorization, assignment, idempotency, audit, and outbox effects. The browser uses a server action and has no direct table access.

**Tech Stack:** PostgreSQL/Supabase RPC, Next.js 16, TypeScript, Tailwind, Vitest, Playwright.

## Global Constraints

- Store title, source, lifecycle status, optional half-open requested dates, and same-tenant assignee only.
- Exclude PII, consent, notes, budget, conversions, merges, booking, finance, and external messaging.
- Owner/manager/sales_agent create; owner/manager list all; sales_agent lists self-assigned or unassigned records; other roles fail closed.
- Successful commands audit and emit outbox events transactionally.

---

### Task 1: Database boundary

**Files:**
- Create: `supabase/migrations/20260722001800_lead_registry_commands.sql`
- Create: `supabase/tests/lead_registry_command_read.sql`
- Modify: `scripts/test-database-foundation.mjs`

- [ ] Write a failing SQL test for `public.create_lead(uuid,text,text,text,date,date,uuid,text,uuid)` and `public.list_leads(uuid)`.
- [ ] Run the local database suite and observe missing-function failure.
- [ ] Add the table, tenant-qualified assignee FK, strict status/range checks, RLS/grant denial, security-definer command/read RPCs, idempotency, audit, and outbox.
- [ ] Re-run the local database suite; assert same-tenant assignment, foreign-tenant denial, sales list filtering, role denial, audit, and outbox.

### Task 2: Workspace boundary and UI

**Files:**
- Create: `src/features/leads/leads-page.tsx`
- Create: `src/features/leads/lead-create-form.tsx`
- Create: `src/features/leads/leads-page.test.tsx`
- Create: `src/features/leads/lead-create-form.test.tsx`
- Create: `src/app/workspace/leads/page.tsx`
- Create: `src/app/workspace/leads/actions.ts`
- Modify: `e2e/access-pending.spec.ts`

- [ ] Write failing component tests for Arabic labels, safe empty state, and server-action form contract.
- [ ] Run focused Vitest tests and observe import failure.
- [ ] Implement a minimal RTL intake for title, source, optional dates, and default `new` status; state explicitly that it does not collect contact, pricing, or reservation data.
- [ ] Implement trusted server action using active membership, safe error mapping, request ID, and path revalidation only after success.
- [ ] Verify component tests and unauthenticated workspace E2E redirect.

### Task 3: Review and verification

**Files:**
- Create: `docs/SECURITY_REVIEW_LEAD_REGISTRY_FOUNDATION.md`

- [ ] Record the tenant, role, grant, PII, idempotency, audit/outbox controls and conversion prerequisites.
- [ ] Run coverage, local database test, E2E, lint, build, dependency audit, and `git diff --check`.
- [ ] Commit only files owned by this feature.
