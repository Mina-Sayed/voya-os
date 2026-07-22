# Voya OS Product Requirements Document

**Status:** Draft for review
**Version:** 0.1
**Date:** 2026-07-21
**Owners:** Product, Engineering, Security, Finance Operations

## 1. Purpose

Voya OS is an Arabic-first, multi-tenant operating system for teams that manage furnished apartment rentals. It brings rental supply, demand, bookings, collections, costs, commissions, owner settlements, approvals, notifications, and audit evidence into one controlled workspace.

This document defines the product boundary and acceptance criteria. It deliberately does not define accounting, commission, tax, cancellation, or approval-threshold rules that require a business decision.

## 2. Outcomes and success measures

### Product outcomes

- Prevent cross-organization data exposure and unauthorized actions.
- Give operations a reliable, conflict-free availability and booking workflow.
- Give finance a traceable, non-destructive record of money movement.
- Make sensitive changes reviewable through maker-checker approvals.
- Let AI assistants accelerate work without becoming a source of record or bypassing policy.
- Provide a usable Arabic RTL experience on mobile and desktop, with equivalent English functionality.

### Initial success measures

Targets must be finalized before launch. Instrument at least:

- confirmed booking overlap attempts blocked by the database;
- booking confirmation and cancellation success/failure rates;
- lead-to-booking conversion and median response time;
- overdue and unreconciled payment counts;
- settlement preparation and approval cycle time;
- approval backlog and rejection rate;
- unauthorized and cross-tenant access denials;
- audit coverage for sensitive events;
- AI suggestion acceptance, correction, refusal, latency, and cost.

## 3. Users and terminology

| Persona | Primary jobs |
|---|---|
| Organization owner (`owner` role) | Configure the organization, manage membership, oversee performance, approve high-risk actions. |
| Manager | Manage day-to-day business, approve permitted actions, supervise sales, operations, and finance. |
| Sales agent | Capture and qualify leads, manage clients, propose suitable inventory, hand off booking requests. |
| Operations | Maintain properties and availability, coordinate stays, handle operational booking tasks. |
| Accountant | Record and reconcile payments and expenses, calculate proposed commissions and settlements, produce finance reports. |
| Viewer | Read only the explicitly permitted organization data. |
| Property owner | External or internal party on whose behalf one or more properties are managed; this is a business record, not the `owner` application role. |

**Organization** is the tenant boundary. Every tenant-owned row must carry `organization_id`, directly or through an enforced parent relation. **Property** means one independently bookable furnished apartment in v1; building/unit hierarchy is an open decision.

## 4. Scope

### In scope for the initial product

- Authentication, organization membership, invitations, role-based authorization, and organization switching.
- Arabic-first RTL responsive UI and full English localization.
- Property-owner and property records, documents/metadata, status, and availability blocks.
- Leads, activities, clients, deduplication assistance, and lead conversion.
- Booking quotes/proposals, booking lifecycle, conflict checks, confirmation, cancellation, and completion.
- Payments, commissions, expenses, owner settlement preparation and approval, with non-destructive correction.
- Configurable approval policies for sensitive actions.
- In-app notifications and a reliable notification outbox; external channels are rollout decisions.
- Append-only audit evidence for important reads and changes as classified by policy.
- Controlled sales, booking, finance, and manager AI assistants.
- Operational, finance, approval, and audit views appropriate to role.

### Explicitly out of scope until decided

- A public marketplace, guest self-service portal, channel-manager integrations, dynamic pricing, smart-lock/IoT control, payroll, full general ledger, tax filing, and jurisdiction-specific invoices.
- Native mobile applications; the initial interface is responsive web.
- Autonomous AI confirmations, cancellations, refunds, posting, reconciliation, commissions, settlements, approvals, or deletion.
- Microservices, a data warehouse, or a vector database unless measured need justifies them.

## 5. Product principles

1. The server and database enforce tenant and permission boundaries; hiding UI controls is not authorization.
2. Confirmed inventory is correct under concurrency, not merely after a UI check.
3. Financial history is corrected by reversal or superseding records, never hard deletion.
4. A sensitive action is proposed, approved by an eligible different actor when required, then executed once.
5. Audit records are append-only, redacted, attributable, and queryable.
6. AI proposes or invokes narrowly scoped tools; deterministic services remain authoritative.
7. Arabic is a first-class product language, not a translated afterthought.

## 6. Functional requirements and acceptance criteria

### FR-1 Identity and tenancy

- A user may belong to multiple organizations through memberships and may have one role per organization in v1.
- The active organization must be explicit in every server request and derived from an authenticated membership, never trusted from model output or client claims alone.
- Invitations, role changes, suspension, and removal are audited.

**Acceptance criteria**

- A user cannot read, infer, export, or mutate another organization's rows by changing identifiers.
- A suspended membership loses access on the next authorized request and active sessions are handled according to the documented revocation policy.
- The last active organization owner cannot be removed or downgraded.
- Service-role database access is restricted to reviewed server/worker paths and never exposed to a browser.

### FR-2 Localization and accessibility

- Arabic is the default locale with `dir="rtl"`; English uses `dir="ltr"`.
- Dates, numbers, currency, names, search, validation, and exported content use locale-aware presentation while storage remains canonical.
- Layouts support mobile, tablet, and desktop and meet WCAG 2.2 AA for supported workflows.

**Acceptance criteria**

- Every production string is localized; missing keys fail CI or are visibly flagged outside production.
- Keyboard navigation, focus order, error association, contrast, and screen-reader labels pass automated and manual checks.
- Mixed Arabic/English names, phone numbers, currencies, and long text do not corrupt reading order or overflow layouts.
- Changing locale preserves the current authorized workflow and does not change stored values.

### FR-3 Property owners, properties, and availability

- Authorized users manage property-owner profiles and independently bookable properties.
- Availability is derived from property status, manual blocks, and confirmed bookings; tentative states are displayed separately.
- Changes to ownership assignment, availability blocks, and property status are audited.

**Acceptance criteria**

- Archived/inactive properties cannot receive new confirmed bookings.
- Availability queries use half-open stays: check-in is included and check-out is excluded.
- Adjacent stays are allowed; any overlap with a confirmed booking is rejected at the database level.
- Date range, property, tenant, and status validation applies equally to UI and API/tool paths.

### FR-4 Leads and clients

- Sales users capture source, contact details, requested dates, preferences, budget as entered, activities, status, assignment, and consent metadata where applicable.
- A lead can be converted/linked to a client without losing history.
- Potential duplicates are warned about but not automatically merged.

**Acceptance criteria**

- Duplicate detection is scoped to the active organization.
- Merge operations preserve source identifiers/history, require permission, and are audited.
- Search results and exports respect field-level sensitivity and role permissions.

### FR-5 Bookings

- Bookings progress through an explicit state machine: `draft`, `pending_approval`, `confirmed`, `cancelled`, `completed`; an optional `held` state is an open decision.
- Confirmation validates tenant, role, property status, dates, client, price snapshot, applicable approval, and availability in one transaction.
- Cancellation never deletes the booking and captures actor, time, reason, and approved financial effects.

**Acceptance criteria**

- Two concurrent transactions cannot create overlapping confirmed bookings for the same organization/property/date range.
- Retrying a confirm/cancel command with the same idempotency key cannot apply it twice.
- Failed confirmation leaves no partial financial or notification state.
- Reconfirmation of a cancelled booking is a separate approved transition with a fresh conflict check.

### FR-6 Financial operations

- Payments, commissions, expenses, settlement statements, and their adjustments are organization-scoped and use integer minor units plus ISO currency.
- Financial records are never hard deleted. Posted records are immutable except for tightly controlled status transitions; corrections use reversal/superseding records.
- Owner settlements snapshot their included line items and totals so later source changes cannot silently rewrite history.
- Finance reports disclose record status and currency and do not combine currencies without a defined conversion policy.

**Acceptance criteria**

- Database controls reject deletion of financial records from every access path.
- Every posted change has an actor or system identity, timestamp, source, reason, idempotency key where applicable, and audit event.
- A reversal links to the original record, has equal/opposite or policy-defined effect, and cannot be applied twice.
- No settlement can be finalized without all required approval and validation checks.
- The system does not infer fees, taxes, commissions, exchange rates, cancellation charges, recognition dates, or owner balances where policy is undefined.

### FR-7 Approvals

- Sensitive commands create immutable approval requests containing action type, target, normalized proposal snapshot/hash, requester, policy version, and expiry.
- Approval policies specify eligible roles, minimum approvers, separation-of-duties rules, and optional thresholds after business validation.
- Editing a proposal after approval invalidates the approval.

**Acceptance criteria**

- A requester cannot approve their own action where maker-checker is required.
- Approval is tenant-scoped, permission-checked at decision and execution time, and consumed at most once.
- Rejected, expired, withdrawn, and superseded requests cannot execute.
- An approval does not override a booking conflict, invalid state transition, or tenant/permission check.

### FR-8 Notifications

- Domain events create notification intents through a transactional outbox.
- Users can see unread/read state and a link to an authorized target.
- Delivery retries are idempotent; provider errors do not roll back an already committed business transaction.

**Acceptance criteria**

- A notification never leaks sensitive details in an unauthorized channel or to a removed member.
- Duplicate worker delivery does not produce duplicate logical notifications.
- Delivery outcome and retry state are observable without storing provider secrets in logs.

### FR-9 Audit and reporting

- Important changes record tenant, actor type/id, action, resource type/id, timestamp, request/correlation ID, outcome, source channel, and redacted before/after or structured delta.
- Sensitive reads/exports and all approval, booking, role, AI-tool, and financial actions are audited.
- Audit rows cannot be changed or deleted by ordinary application roles.

**Acceptance criteria**

- Audit events are written in the same transaction as critical state changes where feasible; otherwise a durable outbox closes the gap.
- Secrets, tokens, full payment credentials, and unnecessary PII never appear in audit payloads.
- Audit queries are tenant-scoped; platform-level access is separately authorized and audited.

### FR-10 AI assistants

- AI assistants use the OpenAI Responses API through a server-side orchestrator and versioned, allowlisted backend tools.
- Model text is untrusted. The policy layer injects authenticated user and organization context, validates schemas, enforces RBAC, rate limits, approval requirements, and idempotency.
- AI may read authorized data and create clearly labeled suggestions/proposals. It cannot directly mutate booking or financial source-of-record tables and cannot approve its own proposals.

**Acceptance criteria**

- Every tool call records agent, model/prompt/tool version, user, tenant, sanitized arguments, result classification, latency, tokens/cost, and approval link if any.
- Cross-tenant prompts, prompt injection, invalid tool arguments, excessive loops, and unavailable providers fail safely.
- A user can review the exact proposed effect before a sensitive command is submitted.
- Core manual workflows remain available during an AI provider outage.

## 7. Cross-cutting edge cases

- Concurrent booking confirmations; booking dates changed while approval is pending; daylight-saving and locale display differences.
- Property archived, reassigned, or blocked after a proposal but before confirmation.
- User role changed or membership removed while a screen, approval, export, or AI run is active.
- Duplicate payment webhook, retry, partial refund, chargeback, failed payment, or payment in another currency.
- Expense or commission corrected after inclusion in a draft or finalized settlement.
- Owner changes mid-stay; historical settlement attribution must not be silently rewritten.
- Approval policy changes while requests are pending; each request retains its policy version and is revalidated at execution.
- Notification recipient becomes unauthorized before delivery.
- AI timeout after a tool result, duplicated Responses API continuation, malicious content in notes/documents, or model output that contradicts database facts.
- Arabic/English mixed input, alternate digits, normalization differences, duplicate phone formats, and time zone boundaries.

## 8. Non-functional requirements

- **Security:** least privilege, MFA requirement for privileged roles before production, secure session handling, RLS defense in depth, encryption in transit/at rest, managed secrets, dependency and infrastructure scanning.
- **Reliability:** target SLOs, recovery point objective, and recovery time objective are open decisions; backups and restore drills are mandatory before launch.
- **Performance:** define p95 targets after expected scale is known; booking conflict checks and tenant-filtered lists must have verified query plans.
- **Observability:** structured redacted logs, metrics, traces, correlation IDs, dashboards, alerts, runbooks, and audit-event health.
- **Delivery:** preview environments contain synthetic data only; migrations are expand/contract, backward compatible, reviewed, and rehearsed; production deploys support rollback without destructive down-migrations.
- **Quality:** all code changes require unit and integration tests plus security review; critical tenancy, booking, approval, and finance invariants receive database and end-to-end tests.

## 9. Assumptions

- One independently bookable property has one calendar in v1.
- Stay ranges are stored as local property dates and interpreted as `[check_in, check_out)`; operational check-in times are separate metadata.
- Supabase Auth is the initial identity provider and PostgreSQL is the authoritative transactional store.
- Vercel hosts the Next.js application; server-side application services own all critical mutations.
- The initial release serves a bounded set of organizations and can use a modular monolith; scale targets remain to be supplied.
- No raw card data is stored. A future payment provider owns PCI-sensitive collection.

## 10. Open product decisions

1. Launch countries, legal entities, privacy/retention obligations, residency constraints, tax and invoicing requirements.
2. Supported currencies, organization/property base currency, conversion source/timing, rounding, and reporting policy.
3. Commission basis, eligibility, rate ownership, timing, cancellations, clawbacks, and rounding.
4. Payment allocation, refunds, chargebacks, deposits, recognition, reconciliation, and write-off rules.
5. Expense categories, evidence requirements, allocation to property/owner/booking, and approval thresholds.
6. Settlement period, cut-off, carry-forward, reserve, adjustment, payout, locking, reopening, and statement rules.
7. Booking quote, hold, expiry, cancellation, amendment, overbooking exception, and pricing/tax/fee policies.
8. Which actions require approval, how many approvers, eligible roles, monetary thresholds, expiry, and emergency override policy.
9. Whether property owners receive portal access and how that maps to application roles.
10. Expected users, organizations, properties, bookings, peak concurrency, SLO, RPO, RTO, and support hours.
11. Notification channels, consent, templates, providers, quiet hours, and delivery guarantees.
12. Data export/deletion rights, retention periods, legal holds, backup retention, and audit retention.

## 11. Release exit criteria

- Product and finance owners approve all launch-blocking open policies.
- Security signs off the threat model, tenant-isolation tests, privileged-access design, secrets handling, and incident runbooks.
- QA passes the release matrix in [TEST_PLAN.md](./TEST_PLAN.md), including concurrent booking and non-deletion tests.
- Database restore and rollback rehearsals succeed against production-like data.
- Arabic RTL and English LTR workflows pass accessibility and domain-expert review.
- AI features pass safety/evaluation thresholds and can be disabled independently.
- Monitoring, paging, audit completeness, support ownership, and financial reconciliation runbooks are operational.
