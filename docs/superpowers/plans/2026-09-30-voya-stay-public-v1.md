# VOYA Stay public V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Implement explicit public property publication, approved media derivatives, public search, and guest requests that enter the existing CRM review workflow.

**Architecture:** A disabled-by-default singleton storefront maps one organization to a safe public listing projection. Staff publish through AAL2 user-JWT RPCs; public server reads use fixed-output service-role-only RPCs over the projection; guest requests use a bounded server route and service-role-only CRM RPC. Booking, occupancy, and payment remain staff-owned.

**Tech Stack:** Next.js 16 App Router, Supabase/PostgreSQL, Supabase Storage, existing CRM, Playwright/Vitest.

**Spec:** `docs/superpowers/specs/2026-09-30-voya-stay-public-v1-design.md` and `docs/adr/ADR-023-voya-stay-public-catalog-and-guest-requests.md`.

## Global Constraints

- Stay on `feat/voya-stay-public-site`; preserve all unrelated dirty work; do not deploy, merge, or mutate managed environments.
- No client-supplied organization ID, direct browser DML, service-role exposure, or access to private property/original image data.
- Public listing projection tables are not directly granted to `anon` or `authenticated`; public reads use fixed-output server-side RPCs.
- The original private image bucket remains unchanged; only selected, metadata-stripped WebP derivatives are placed in the dedicated public media bucket.
- Public listing fields are an allowlist; projection tables have no direct client grants; publication is owner/manager+AAL2 and only for the configured storefront organization.
- Guest submissions become CRM leads with consent/idempotency/audit/outbox; no booking/payment/availability hold.
- Missing storefront/privacy/rate-limit configuration fails closed.

## Review Focus

- An absent/disabled storefront must return no listings and reject guest requests.
- A malicious client must not publish another organization or reference another property's image.
- Public media must contain no original private path or image metadata and must disappear from the catalog on unpublish.
- Retried guest requests must not duplicate leads or change payload under the same idempotency key.
- A guest request must not change booking status, approvals, or occupancy even when dates currently appear available.

---

### Task 1: Public catalog schema and publish/CRM commands

**Files:**
- Create: one CLI-generated migration under `supabase/migrations/`
- Create: `supabase/tests/voya_stay_public_v1.sql`
- Modify: `src/app/workspace/leads/actions.ts` and existing lead display types/RPC projection as needed

**Interfaces:**
- Storefront singleton is unassigned/disabled by default.
- Authenticated functions: `publish_voya_stay_public_listing_v1(organizationId, propertyId, publicFields, mediaPaths, idempotencyKey, requestId)` and `unpublish_voya_stay_public_listing_v1(organizationId, listingId, expectedVersion, idempotencyKey, requestId)`.
- Service-role read RPC: `list_voya_stay_public_listings_v1(searchCriteria)` returns only public fields, media URLs, and advisory availability; it accepts no organization ID.
- Service-role write RPC: `capture_voya_stay_lead_v1(publicSlug, guestContact, dates, guests, consentVersion, contactHash, idempotencyKey, requestId)` writes `source='voya_stay'` and consent evidence.

- [ ] Write SQL proofs for default-closed, role/AAL2, cross-tenant, anon grants, public field allowlist, idempotency, and no booking/occupancy writes.
- [ ] Run the focused SQL proof and confirm it fails because the V1 contract is absent.
- [ ] Generate the migration with `supabase migration new voya_stay_public_v1`.
- [ ] Implement the minimal schema/RPC/grants and run `npm run test:db` on a loopback disposable `*_test` database.

### Task 2: Staff publication and media derivative pipeline

**Files:**
- Modify: `src/app/workspace/properties/actions.ts` and `src/app/workspace/properties/page.tsx`
- Modify: `src/features/properties/properties-page.tsx`
- Modify: `next.config.ts` for the configured Supabase public-media image origin
- Create: public-listing form/types/tests under `src/features/properties/`
- Create: server-only stay media/config helpers under `src/lib/stay/`

**Interfaces:**
- `publishPropertyOnStayAction` accepts public copy, selected private image IDs, and an idempotency key.
- Server transforms selected source images to metadata-stripped WebP, uploads only derivatives to public `voya-stay-public-media`, then commits the public projection through user-JWT RPC. Storage cleanup compensates if the RPC fails.
- Unpublish hides the projection before derivative cleanup; source images are never deleted or moved.

- [ ] Add focused failing tests for authorization, invalid images, public-copy transform, rollback, and unpublish behavior.
- [ ] Implement the publication UI/action and run focused tests.

### Task 3: Public search/detail and guest request to CRM

**Files:**
- Modify: `src/app/stay/search/page.tsx`, `src/app/stay/property/[slug]/page.tsx`, and `src/features/stay/`
- Create: `src/app/api/stay/requests/route.ts`
- Create: a public guest request form and submission state under `src/features/stay/`
- Create: public catalog and guest-request adapter tests

**Interfaces:**
- `listVoyaStayPublicListings(criteria)` reads the allowlisted published projection.
- The public catalog adapter calls only `list_voya_stay_public_listings_v1` and returns allowlisted projection/media URLs; it accepts no organization ID.
- The guest route calls `capture_voya_stay_lead_v1`; it accepts no organization ID and returns receipt-only language.
- Illustrative demo content is available only behind an explicit local/test flag and never in production.

- [ ] Add failing unit tests for public filtering, date advisory, no-storefront, input/origin/consent/rate limits, idempotency, and generic errors.
- [ ] Implement server read/media/request adapters and production pages.
- [ ] Extend the existing CRM Leads UI to identify `voya_stay` requests and show the requested listing.

### Task 4: End-to-end flow, accessibility, docs, release gates

**Files:**
- Modify: `e2e/stay-search-demo.spec.ts` or add focused public-flow E2E
- Modify: `docs/design/VOYA-UI-SPEC.md`, `docs/design/VISUAL-QA.md`, memory/ADR index, and `.agent-runs/voya-stay-public-site.md`

- [ ] Test synthetic publish → public search/detail/media → request → CRM lead review, plus denial/unpublish/rate-limit/error states.
- [ ] Capture desktop/mobile screenshots and compare the live surfaces with the approved VOYA reference.
- [ ] Run unit, lint, typecheck, DB, E2E, build, production smoke, npm audit, and available security scans.
- [ ] Self-review the migration, changed UI anti-patterns, all public/privileged grants, and the goal requirements. Keep managed rollout and missing real content/config labeled as external release gates.
