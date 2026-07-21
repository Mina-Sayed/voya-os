# Session and Membership Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the magic-link callback boundary and enforce an active, server-resolved organization membership before a user enters `/workspace`.

**Architecture:** A route handler exchanges the one-time code with Supabase using request/response cookie adapters. It then queries the caller-scoped `organization_memberships` table and redirects only an active member to `/workspace`; all missing/invalid/inactive cases share `/access-pending`. The workspace remains a guarded shell until live read models are introduced.

**Tech Stack:** Next.js App Router route handlers, `@supabase/ssr`, TypeScript, Vitest, Playwright.

## Global Constraints

- Callback return paths are fixed server-side; no arbitrary `next` parameter is accepted.
- Membership and organization identity come from the authenticated database row, never cookies, URLs, browser state, or AI output.
- Users without an active membership receive the same access-pending outcome regardless of account or organization state.
- The guarded workspace exposes no booking, finance, approval, audit, or AI mutation.

---

### Task 1: Membership resolution domain rule

**Files:**
- Create: `src/features/auth/active-membership.ts`
- Create: `src/features/auth/active-membership.test.ts`

- [x] Write failing tests for one active membership, no membership, suspended membership, and multiple active memberships.
- [x] Implement deterministic membership selection that accepts exactly one active membership and rejects ambiguous context.
- [x] Run focused tests green.

### Task 2: Callback and guarded workspace

**Files:**
- Create: `src/lib/supabase/route-client.ts`
- Create: `src/app/auth/callback/route.ts`
- Create: `src/app/access-pending/page.tsx`
- Create: `src/app/workspace/page.tsx`

- [x] Build a route-response Supabase client with request cookie reads and response cookie writes.
- [x] Exchange only a present `code`, query caller-scoped memberships, and redirect to fixed `/workspace` or `/access-pending` paths.
- [x] Protect `/workspace` by resolving the session and active membership server-side; render an Arabic guarded-shell state without fixture data.

### Task 3: Browser and security verification

**Files:**
- Create: `e2e/access-pending.spec.ts`
- Modify: `docs/SECURITY_REVIEW_AUTH_BOUNDARY.md`

- [x] Add E2E coverage for direct unauthenticated workspace access and the Arabic access-pending route.
- [x] Run lint, coverage, E2E, build, database integration, audit, visual review, and commit after clean diff checks.
