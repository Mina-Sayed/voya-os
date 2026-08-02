# Voya OS Core Operations, Design C, CRM, AI, WhatsApp, and SaaS Program Design

**Status:** Approved program direction; Design C workspace, booking lifecycle, staff inbox, task registry, fleet/transport foundation, and governed Agent Center foundation implemented; final release verification pending
**Date:** 2026-07-30
**Scope:** A phased product program, not one implementation batch.

---

# Decision

Voya OS will remain a **server-owned, Arabic-first modular monolith**.

The program will deliver:

* An internal identity, organization, and role-based access foundation.
* A complete operational engine for owners, properties, units, leads, bookings, payments, commissions, staff tasks, cars, and airport transfers.
* The approved **Design C** operational experience with a premium hospitality visual language, persistent workspace shell, live tenant data, and equivalent mobile workflows.
* A tenant-scoped CRM and WhatsApp inbox with consent-aware lead capture and human staff ownership.
* A governed AI Agent Center that allows authorized staff to inspect agent runs, tools, statuses, policy decisions, costs, and human takeovers.
* Controlled self-service SaaS onboarding and WhatsApp outbound automation only after the internal operating system is stable and verified.

These capabilities are connected, but they are independently releasable products.

Each slice must be specified, planned, implemented, reviewed, tested, and released separately.

Broad approval for the program does not authorize:

* Production database migrations.
* External provider configuration.
* Customer messaging.
* Payment processing.
* AI-controlled booking decisions.
* Production deployment.

---

# Product Principles

Voya OS must follow these principles across every program slice:

1. **The server owns business decisions.**

   The browser, AI model, WhatsApp payload, and external providers may request actions, but they do not determine organization context, authorization, pricing, booking state, payment state, or role permissions.

2. **Manual operations must always remain available.**

   Disabling AI, WhatsApp, or an external provider must never prevent staff from managing leads, units, bookings, payments, tasks, or customers manually.

3. **Every operational action must be auditable.**

   Important changes must record the actor, organization, source channel, previous state, new state, timestamp, reason, and correlation ID.

4. **No demonstration data may be presented as live data.**

   Fixture or example records must be visibly marked as demonstration content and must never appear inside a real tenant workspace as operational truth.

5. **Every capability must fail closed.**

   Invalid organization context, inactive membership, insufficient permission, replayed events, malformed commands, or stale state must result in denial rather than partial execution.

6. **Every capability must be independently disabled.**

   Feature flags and kill switches must exist by environment, organization, agent, provider channel, and major product module.

---

# Product Boundaries

## Internal Identity and Workspace Access

The first identity release is designed for VOYA staff and invited organization members.

Authentication supports:

* Email and password.
* Email confirmation when required.
* Password recovery.
* Secure session refresh.
* Organization invitations.
* Multiple organization memberships.
* Active organization selection.

An authenticated user with several memberships must select a validated active organization.

A stale, suspended, deleted, or foreign organization selection must fail closed.

The browser may not choose:

* Its own role.
* Its own organization membership.
* An arbitrary organization identifier.
* A privileged workspace context.

The trusted server context supplies:

* Actor ID.
* Organization ID.
* Membership ID.
* Role.
* Locale.
* Session assurance level.
* Source channel.
* Request ID.
* Correlation ID.

Public self-service organization creation is not part of the first internal release.

It is introduced later as a SaaS capability after the internal product, support process, rate limits, abuse controls, and tenant recovery procedures are ready.

---

## Core Operations Engine

The Core Operations Engine is the central domain of Voya OS.

It must exist before AI automation or advanced WhatsApp automation is enabled.

The engine manages:

* Organizations.
* Staff memberships.
* Owners.
* Owner contact methods.
* Properties.
* Units.
* Unit images and amenities.
* Unit pricing.
* Unit availability.
* Clients.
* Leads.
* Lead requirements.
* Booking requests.
* Owner approvals.
* Deposits.
* Booking confirmations.
* Active stays.
* Check-ins.
* Check-outs.
* Extensions.
* Cancellations.
* Client commissions.
* Owner commissions.
* Employee commissions.
* Operational tasks.
* Staff assignments.
* Cars.
* Drivers.
* Car rentals.
* Airport transfers.
* Payment records.
* Owner payouts.
* Audit history.

The first operational success criterion is one complete end-to-end workflow:

> A staff member receives a lead, records the client’s requirements, matches an available unit, requests owner approval, records the deposit, confirms the booking, assigns operational tasks, manages check-in, and completes check-out or extension.

The system is not considered an operating system until that workflow works using real tenant data.

---

## Design C Workspace

The Design C workspace replaces any fixture-style or public demonstration dashboard with a live tenant-scoped operational interface.

The approved visual direction uses:

* Premium hospitality styling.
* Dark green, ivory, neutral, and restrained gold surfaces.
* Clear information hierarchy.
* Calm data density.
* Persistent workspace navigation.
* Responsive layouts.
* Arabic-first RTL support.
* Equivalent English LTR support.
* Touch-friendly interactions.
* Role-safe primary actions.

Desktop uses:

* A persistent RTL-aware side navigation.
* Organization switcher.
* Global search.
* Global action menu.
* Contextual detail drawers.
* Data tables.
* Operational calendars.
* Filters and saved views.

Mobile uses:

* Task-oriented bottom navigation.
* Full-screen or bottom-sheet flows.
* Touch-friendly calendars.
* Compact search and filters.
* Equivalent operational actions.
* No feature-critical desktop-only path.

Every workspace surface follows one standard pattern:

1. Page title and operational purpose.
2. Role-safe primary action.
3. Search and filters when data exists.
4. Loading state.
5. Empty state.
6. Error state.
7. Permission-denied state.
8. Clear return path to the persistent application shell.

Unavailable capabilities must either be absent or explicitly labeled as unavailable.

A control must never appear actionable when the underlying capability does not exist.

---

## CRM and WhatsApp Inbox

The first WhatsApp release is a staff-operated communication inbox, not an autonomous customer service agent.

The CRM and inbox manage:

* Contacts.
* Contact methods.
* Lead sources.
* Consent evidence.
* Opt-out status.
* WhatsApp conversations.
* Message events.
* Staff assignments.
* Internal notes.
* Conversation-to-lead conversion.
* Human handoff.
* Conversation status.
* Channel audit history.

Staff can:

* View permitted conversations.
* Assign conversations.
* Reply manually.
* Add internal notes.
* Capture customer requirements.
* Convert a conversation into a lead.
* Link a conversation to an existing client.
* Transfer ownership to another staff member.
* Close or reopen a conversation.

No AI auto-reply is required for the first inbox release.

This allows VOYA to validate the real workflow, customer questions, staffing requirements, response times, and consent model before automated responses are introduced.

---

## AI Agent Center

An agent is a bounded server-side orchestration profile.

It is not:

* An autonomous database user.
* A privileged staff member.
* A source of authorization.
* A direct SQL client.
* A direct payment processor.
* A booking approver.

Each visible run records:

* Initiating actor.
* Organization.
* Agent name and version.
* Lifecycle status.
* Safe summary.
* Tool calls.
* Policy outcome.
* Cost class.
* Latency class.
* Correlation ID.
* Handoff reference.
* Proposal reference.
* Failure or refusal reason.

Authorized staff may inspect only the runs permitted by their role and organization.

Raw prompts, hidden reasoning, provider secrets, tokens, restricted CRM fields, and unredacted sensitive content are not exposed simply because a user can view an agent run.

The initial agent set is:

* Sales Agent.
* Availability Agent.
* Operations Agent.
* Manager Summary Agent.
* WhatsApp Assist Agent.

All agent tools are:

* Versioned.
* Allowlisted.
* Tenant-scoped.
* Schema-validated.
* Policy-checked.
* Audited.
* Rate-limited.

AI may:

* Read authorized operational facts.
* Search available units.
* Summarize permitted activity.
* Draft a customer reply.
* Draft an owner message.
* Suggest a unit match.
* Suggest an operational task.
* Create an explicitly labeled lead proposal.
* Create an explicitly labeled booking proposal.
* Request human review.

AI may not:

* Confirm a booking.
* Change or invent pricing.
* Negotiate a final price.
* Mark a payment as received.
* Process a payment.
* Approve an owner request.
* Modify memberships.
* Change permissions.
* Execute arbitrary SQL.
* Execute arbitrary HTTP requests.
* Bypass tenant boundaries.
* Bypass role controls.
* Bypass database constraints.
* Send unrestricted proactive messages.

Per-agent and per-channel kill switches stop new automated work without affecting manual workflows.

---

## SaaS Self-Service Workspace

Public self-service registration is introduced only after the internal system is proven.

Email and password registration creates:

* One new private organization.
* One active owner membership.
* One user profile when absent.
* One audit event.

These records are created atomically through a dedicated server-owned bootstrap command.

Self-service registration never:

* Joins an existing organization.
* Allows the browser to select a role.
* Reveals another organization.
* Accepts an arbitrary organization ID.
* Creates multiple organizations through request replay.
* Bypasses email verification or abuse controls.

The bootstrap command must be:

* Idempotent.
* Rate-limited.
* Audited.
* Replay-safe.
* Transactional.
* Protected against duplicate organization creation.

Public SaaS onboarding also requires:

* Organization naming rules.
* Server-generated slug rules.
* IP and email rate limits.
* Email confirmation policy.
* Support recovery process.
* Tenant deletion and export process.
* Subscription and plan boundaries when billing is introduced.

---

## WhatsApp Agent and Controlled Outbound

Voya OS uses a server-side provider port.

The initial provider adapter is the Meta WhatsApp Business Cloud API.

The web UI, application services, domain logic, and agent runtime depend on the provider port rather than Meta-specific implementation details.

Inbound webhooks must be:

* Signature verified.
* Replay protected.
* Deduplicated.
* Rate-limited.
* Persisted as auditable channel events.
* Resolved to an enabled tenant channel before routing.

The WhatsApp agent may:

* Answer approved informational questions.
* Ask clarifying questions.
* Collect the customer’s name.
* Collect a phone number.
* Collect requested dates.
* Collect guest count.
* Collect location and unit preferences.
* Create or update a consent-aware lead through an approved command.
* Draft responses.
* Transfer the conversation to staff.

The agent must not:

* Confirm a booking.
* Quote an unapproved price.
* Negotiate pricing.
* Take payment.
* Mark payment as received.
* Disclose restricted data.
* Modify memberships.
* Approve an action.
* Send arbitrary proactive messages.

Outbound messages are enabled only when all of the following are true:

* The tenant channel is enabled.
* The organization policy permits the message.
* The customer is inside the valid customer-service conversation window, or an approved message template is used.
* Consent and opt-out state allow the message.
* Quiet-hour policy allows delivery.
* The agent and channel kill switches are enabled.
* The message is recorded through the transactional delivery system.

Human takeover immediately stops automated replies until an authorized staff member releases the conversation.

---

# Architecture and Trust Boundaries

```mermaid
flowchart LR
    Staff[Staff or SaaS User] --> Web[Next.js Workspace and Authentication]
    Customer[WhatsApp Customer] --> Meta[Meta WhatsApp Cloud API]

    Web --> Context[Trusted Workspace Context]
    Meta --> Hook[Verified Webhook Adapter]

    Hook --> Channel[Channel Resolver and Inbox]
    Context --> Services[Server-Owned Application Services]
    Channel --> Services

    Services --> Policy[RBAC, Consent, Idempotency, Audit and AI Policy]
    Policy --> DB[(Supabase PostgreSQL and RLS)]

    Policy --> AI[OpenAI Responses Adapter]
    AI --> Tools[Versioned Allowlisted Tools]
    Tools --> Services

    Services --> Outbox[Transactional Outbox]
    Outbox --> Worker[Dedicated Delivery Worker]
    Worker --> Meta
```

The trusted context supplies:

* Actor.
* Organization.
* Membership.
* Role.
* Locale.
* Session assurance.
* Source channel.
* Request ID.
* Correlation ID.

The following inputs do not choose trusted context:

* Browser parameters.
* AI output.
* WhatsApp payloads.
* Provider callbacks.
* Query-string organization IDs.
* Client-controlled role values.

PostgreSQL constraints, RLS policies, and server-owned authorization remain the final tenancy boundary.

Sensitive data includes:

* Contact fields.
* Phone numbers.
* Consent evidence.
* WhatsApp conversations.
* Message content.
* AI traces.
* Provider references.
* Payment evidence.
* Owner and customer documents.

Sensitive data requires:

* Field-level access policy.
* Role checks.
* Tenant checks.
* Audit records.
* Retention limits.
* Deletion or anonymization procedures.
* Redaction before AI processing.
* Redaction before application logging.

Secrets, access tokens, callback signatures, full provider payloads, and unrestricted message content must not enter ordinary logs or AI prompts.

---

# Program Slices and Dependencies

## Slice 0 — Release Baseline Reconciliation

### Deliverable

Establish the true current product and security baseline.

### Includes

* Reconcile dirty or incomplete migrations.
* Confirm build and lint state.
* Confirm test state.
* Confirm authentication flows.
* Confirm RLS coverage.
* Confirm protected-route behavior.
* Confirm preview environment.
* Confirm dependency and container scanner status.
* Document known security and release gaps.
* Remove misleading fixture or public dashboard claims.

### Depends On

* Current repository.
* Current Supabase configuration.
* Current deployment and CI state.

### Release Boundary

No new product functionality.

This slice establishes accurate evidence of the current system.

Slice 0 is mandatory before any production-readiness claim.

---

## Slice 1 — Internal Identity, Organizations, and RBAC

### Deliverable

A secure internal workspace identity model for VOYA staff.

### Includes

* Email/password authentication.
* Email confirmation when required.
* Password recovery.
* User profile.
* Organization.
* Membership.
* Invitation flow.
* Active organization selection.
* Owner role.
* Manager role.
* Sales role.
* Operations role.
* Read-only or auditor role when needed.
* Trusted workspace context.
* Cross-tenant denial tests.
* Inactive membership denial.
* Suspended user denial.
* Last-owner protection.
* Multi-organization selection.

### Depends On

* Slice 0.
* Existing authentication boundary.
* Supabase authentication.
* Server-owned session context.

### Release Boundary

Internal preview only until:

* Cross-tenant tests pass.
* Membership tests pass.
* Invitation tests pass.
* Session refresh tests pass.
* Protected route tests pass.

Public self-service sign-up is not included.

---

## Slice 2 — Core Operations Engine

### Deliverable

A complete internal operational workflow using real tenant data.

### Includes

* Owner registry.
* Properties.
* Units.
* Unit amenities.
* Unit media.
* Pricing.
* Availability calendar.
* Clients.
* Leads.
* Lead requirements.
* Booking requests.
* Owner approval.
* Deposit tracking.
* Booking confirmation.
* Check-in.
* Check-out.
* Extension.
* Cancellation.
* Client commission.
* Owner commission.
* Staff commission.
* Operational tasks.
* Staff assignment.
* Cars.
* Drivers.
* Car rentals.
* Airport transfers.
* Payment records.
* Owner payouts.
* Operational audit log.

### Depends On

* Slice 1.
* Role and tenant context.
* Database constraints.
* RLS policies.
* Audited server commands.

### Release Boundary

Internal organization only.

No AI-controlled actions.

No WhatsApp automation.

No payment processing provider.

---

## Slice 3 — Design C Live Workspace

### Deliverable

The complete responsive operational user interface connected to live tenant data.

### Includes

* Persistent application shell.
* Organization switcher.
* Role-safe navigation.
* Global search.
* Global action menu.
* Live dashboard.
* Lead screens.
* Client screens.
* Owner screens.
* Property and unit screens.
* Availability calendar.
* Booking pipeline.
* Booking detail drawer.
* Check-in and check-out workflow.
* Commission views.
* Task management.
* Car and transfer workflows.
* Loading states.
* Empty states.
* Error states.
* Permission-denied states.
* Arabic RTL.
* English LTR.
* Desktop workflow.
* Tablet workflow.
* Mobile workflow.
* Keyboard accessibility.
* Touch accessibility.
* Focus visibility.
* Contrast verification.

### Depends On

* Slice 1 identity contract.
* Slice 2 operational services.
* Protected tenant reads and commands.

### Release Boundary

Feature-flagged internal preview.

No fixture dashboard may be represented as live operations data.

---

## Slice 4 — CRM, Consent, and Staff-Operated WhatsApp Inbox

### Deliverable

A tenant-scoped CRM and human-operated WhatsApp inbox.

### Includes

* Normalized contact methods.
* Lead source.
* Consent evidence.
* Opt-out state.
* WhatsApp tenant channels.
* Conversations.
* Message events.
* Staff assignment.
* Internal notes.
* Manual replies.
* Conversation-to-lead conversion.
* Customer-to-existing-client matching.
* Human takeover.
* Conversation status.
* Verified inbound webhooks.
* Replay protection.
* Deduplication.
* Channel kill switch.
* Provider sandbox tests.

### Depends On

* Slices 1–3.
* Field-level CRM policy.
* Meta sandbox configuration.
* Provider adapter.
* Tenant channel resolution.

### Release Boundary

Internal test organization and provider sandbox only.

Inbound and human-operated workflows are delivered before AI auto-replies.

---

## Slice 5 — AI Assist and Agent Center

### Deliverable

Governed AI assistance operating on real VOYA workflows.

### Includes

* Sales Agent.
* Availability Agent.
* Operations Agent.
* Manager Summary Agent.
* WhatsApp Assist Agent.
* AI run history.
* Tool-call history.
* Agent versioning.
* Proposal records.
* Human review.
* Human takeover.
* Stop and cancellation behavior.
* Cost classifications.
* Latency classifications.
* Agent kill switches.
* Prompt-injection resistance.
* Redacted traces.
* Manual fallback.

### Depends On

* Slices 2–4.
* Stable domain commands.
* Stable authorization.
* Stable CRM data policy.
* Versioned allowlisted tools.
* Approved AI provider configuration.

### Release Boundary

Internal test organization first.

AI produces drafts, recommendations, summaries, and proposals.

AI does not perform final booking, pricing, payment, approval, membership, or permission actions.

---

## Slice 6 — SaaS Self-Service and Controlled WhatsApp Outbound

### Deliverable

Controlled external onboarding and production-ready outbound communication.

### Includes

* Public email/password registration.
* Private organization bootstrap.
* Owner membership bootstrap.
* Email verification.
* Abuse controls.
* Organization naming and slug rules.
* Support recovery process.
* Tenant onboarding.
* Tenant feature flags.
* Approved WhatsApp templates.
* Conversation-window enforcement.
* Opt-out enforcement.
* Quiet hours.
* Delivery worker.
* Delivery attempts.
* Retry policy.
* Dead-letter handling.
* Per-tenant quotas.
* Per-tenant channel kill switch.
* Canary rollout.

### Depends On

* Slices 1–5.
* Approved privacy policy.
* Approved retention policy.
* Approved consent wording.
* Meta Business configuration.
* Approved templates.
* Operational staffing policy.
* Delivery worker lifecycle.
* Support and incident procedures.

### Release Boundary

Tenant-by-tenant canary rollout.

Outbound automation remains disabled by default.

---

# Core Domain State Machines

## Lead Lifecycle

```text
new
→ contacted
→ qualified
→ unit_matched
→ owner_pending
→ deposit_pending
→ converted
```

Alternative terminal states:

```text
lost
cancelled
duplicate
spam
```

A lead may not become converted without a validated booking reference.

---

## Booking Lifecycle

```text
draft
→ owner_pending
→ deposit_pending
→ confirmed
→ checked_in
→ checked_out
```

Alternative states:

```text
rejected
cancelled
expired
no_show
```

Extensions are recorded as explicit booking extension records or reviewed booking amendments.

They must not silently overwrite the original stay history.

---

## Operational Task Lifecycle

```text
open
→ assigned
→ in_progress
→ completed
```

Alternative states:

```text
blocked
cancelled
failed
```

Every task records:

* Owner.
* Assignee.
* Due date.
* Priority.
* Related booking, unit, car, or conversation.
* Completion evidence when required.

---

## AI Run Lifecycle

```text
queued
→ running
→ completed
```

Alternative states:

```text
waiting_for_human
failed
refused
cancelled
stopped
```

Only server policy may perform lifecycle transitions.

---

## WhatsApp Conversation Lifecycle

```text
open
→ assigned
→ waiting_for_customer
→ waiting_for_staff
→ resolved
```

Additional states:

```text
human_takeover
opted_out
blocked
archived
```

Automated replies are prohibited while the conversation is in human takeover.

---

# Core Business Invariants

The database and server command layer must enforce the following:

1. A confirmed unit booking may not overlap another confirmed or active booking for the same unit.

2. A booking may not become confirmed without owner approval unless an explicitly documented owner policy permits pre-approval.

3. The browser may not directly update booking lifecycle states.

4. A deposit is not considered received solely because a client claims it was sent.

5. Payment state changes require authorized human confirmation or a trusted payment-provider event in a future payment slice.

6. Cancelled, rejected, or expired bookings do not block unit availability.

7. An extension must retain the original stay history and create an auditable change.

8. Commission calculations must use versioned rules.

9. Manual commission overrides require permission, reason, and audit history.

10. Any price change after a customer quote must record the old price, new price, actor, and reason.

11. Staff may not view restricted contact or financial fields without explicit role permission.

12. AI proposals must always remain visibly labeled as AI-generated until accepted by an authorized user.

13. AI may not directly change booking, payment, membership, pricing, or approval states.

14. WhatsApp messages may not be routed before the tenant channel is resolved.

15. A provider event may be processed only once for the same tenant and provider event identity.

---

# Permission Model

| Action                           | Owner |      Manager |        Sales |   Operations | Read-Only |
| -------------------------------- | ----: | -----------: | -----------: | -----------: | --------: |
| View operational dashboard       |   Yes |          Yes |      Limited |      Limited |   Limited |
| Create lead                      |   Yes |          Yes |          Yes |          Yes |        No |
| View full client contact details |   Yes |          Yes | Policy-based | Policy-based |        No |
| Add or edit owner                |   Yes |          Yes |           No |      Limited |        No |
| Add or edit property             |   Yes |          Yes |      Limited |      Limited |        No |
| Match a unit to a lead           |   Yes |          Yes |          Yes |          Yes |        No |
| Request owner approval           |   Yes |          Yes |          Yes |      Limited |        No |
| Confirm booking                  |   Yes |          Yes |           No |           No |        No |
| Override price                   |   Yes | Policy-based |           No |           No |        No |
| Confirm deposit                  |   Yes |          Yes |           No | Policy-based |        No |
| Assign operational task          |   Yes |          Yes |      Limited |          Yes |        No |
| Complete check-in/check-out      |   Yes |          Yes |      Limited |          Yes |        No |
| Edit commission rules            |   Yes |           No |           No |           No |        No |
| View financial data              |   Yes | Policy-based |      Limited |      Limited |        No |
| Take WhatsApp handoff            |   Yes |          Yes |          Yes |          Yes |        No |
| Release WhatsApp automation      |   Yes |          Yes | Policy-based | Policy-based |        No |
| View AI runs                     |   Yes |          Yes |  Own/related |  Own/related |   Limited |
| Stop an agent                    |   Yes |          Yes |      Limited |      Limited |        No |
| Manage memberships               |   Yes | Policy-based |           No |           No |        No |

Exact field-level visibility must be defined before production activation.

---

# Data and Interface Decisions

## Server Commands

All sensitive writes are performed through dedicated server-owned commands.

Examples include:

* `createLead`
* `updateLeadRequirements`
* `createOwner`
* `createProperty`
* `createUnit`
* `setUnitAvailability`
* `requestOwnerApproval`
* `recordOwnerDecision`
* `recordDeposit`
* `confirmBooking`
* `checkInBooking`
* `checkOutBooking`
* `extendBooking`
* `cancelBooking`
* `assignOperationalTask`
* `completeOperationalTask`
* `createCarRental`
* `createAirportTransfer`
* `takeConversation`
* `releaseConversation`
* `createAIProposal`
* `acceptAIProposal`
* `stopAgentRun`

Commands must validate:

* Actor.
* Organization.
* Membership.
* Role.
* Input schema.
* Current domain state.
* Idempotency key.
* Tenant ownership.
* Policy rules.
* Database invariants.

---

## CRM v2

CRM v2 extends the safe lead registry through additive migrations.

It introduces:

* Normalized contact methods.
* Consent evidence.
* Opt-out evidence.
* Source channel.
* Message references.
* Conversation references.
* Lead ownership.
* Field-level access policy.
* Retention classification.

Uncontrolled free-text fields must not become an unreviewed storage location for sensitive personal information.

---

## Agent Center Data

The Agent Center persists:

* `ai_runs`
* `ai_tool_calls`
* `ai_proposals`
* `ai_handoffs`
* `ai_policy_decisions`
* `ai_run_events`

State changes are immutable or event-like.

Only server policy performs transitions.

---

## WhatsApp Data

WhatsApp uses separate models for:

* Tenant channel.
* Provider account reference.
* Conversation.
* Message event.
* Delivery attempt.
* Handoff.
* Consent evidence.
* Opt-out event.
* Approved template.
* Provider webhook event.

Provider payloads are deduplicated using tenant and provider event identity.

Messages link to leads only after:

* Tenant resolution.
* Authorization.
* Consent-aware validation.
* Approved server command execution.

---

## Transactional Outbox

External delivery requires a completed outbox lifecycle.

The worker must support:

* Claiming.
* Locking.
* Delivery.
* Completion.
* Retry.
* Exponential backoff.
* Dead-letter state.
* Idempotent provider reference handling.
* Operational visibility.
* Retention.

No external delivery path is enabled until the outbox lifecycle is designed and tested.

---

# Documentation Reconciliation

The following documents remain authoritative for their existing security principles but require updates during the relevant program slices.

## PRD.md

### Keep

* Tenant isolation.
* Human-controlled AI.
* RTL support.
* Audited commands.
* Manual fallback.

### Add

* Core Operations Engine.
* Internal-first identity.
* End-to-end booking workflow.
* Design C live workspace criteria.
* CRM consent model.
* WhatsApp inbox and handoff boundary.
* SaaS self-service release boundary.
* Explicit outbound messaging policy.

---

## ARCHITECTURE.md

### Keep

* Modular monolith.
* Ports and adapters.
* Transactional outbox.
* PostgreSQL RLS.
* Server-owned services.

### Add

* Trusted workspace context.
* Core operations modules.
* Booking state machine.
* Commission service.
* Agent control plane.
* Provider adapter and webhook boundary.
* Worker ownership.
* Feature-flag boundaries.

---

## DATABASE.md

### Keep

* Tenant keys.
* RLS.
* Audit history.
* AI run and tool-call concepts.

### Add

* Owners.
* Properties.
* Units.
* Availability.
* Booking lifecycle.
* Deposits.
* Commission rules.
* Tasks.
* Cars and transfers.
* Contacts and consent.
* Conversations.
* Delivery attempts.
* Handoffs.
* Bootstrap invariants.
* Retention classifications.

---

## AI_AGENTS.md

### Keep

* Allowlisted tools.
* OpenAI adapter.
* Human approval.
* Kill switches.
* Server-owned authorization.

### Add

* Agent Center read model.
* Proposal workflow.
* Availability Agent.
* Operations Agent.
* Manager Summary Agent.
* WhatsApp Assist Agent.
* Run visibility and RBAC.
* Stop behavior.
* Human handoff states.
* Redaction rules.

---

## USER_FLOWS.md and PERMISSIONS.md

### Keep

* Role-based workflows.
* Active membership model.
* Tenant-safe navigation.

### Add

* Internal invitation.
* Active organization selection.
* Lead-to-booking workflow.
* Owner approval.
* Deposit confirmation.
* Check-in/check-out.
* Extension.
* Commission review.
* WhatsApp inbox.
* Human takeover.
* Agent proposal review.
* Opt-out.
* Public SaaS registration.
* Per-field visibility.

---

## TEST_PLAN.md

### Keep

* Security-first release gates.
* Database tests.
* Browser tests.
* Independent security review.

### Add

* Booking overlap.
* Owner approval.
* Deposit validation.
* Commission calculation.
* Cross-tenant operational denial.
* Responsive mobile workflow.
* RTL and LTR.
* Consent.
* Webhook verification.
* Replay protection.
* AI proposal authorization.
* Prompt injection resistance.
* Human handoff.
* Opt-out.
* Delivery retry and dead-letter behavior.
* Self-service bootstrap abuse cases.

---

## SECURITY_REVIEW_AUTH_BOUNDARY.md

### Keep

* Server-only configuration.
* Safe redirects.
* Trusted session context.
* Tenant denial.

### Update

Statements that assume:

* Organizations are only platform-provisioned.
* A user always has exactly one membership.

These assumptions become superseded when validated self-service bootstrap and multi-organization selection are released.

---

## Historical Foundation Plans and Reviews

Historical plans remain evidence of the controls that existed when those documents were produced.

They must not be rewritten to imply that later capabilities were already implemented or verified.

Add supersession notes rather than altering historical evidence.

---

# Required Policy Decisions Before Activation

The technical design does not invent the following policies.

Each decision is a release precondition for the capability that uses it.

## Privacy and Data

* Launch countries.
* Legal processing basis.
* Customer privacy notice.
* Consent wording.
* Retention windows.
* Deletion windows.
* Anonymization rules.
* Data export process.
* Legal-hold process.
* Contact and conversation field classifications.

## WhatsApp

* Meta Business account ownership.
* Verified sending number.
* Approved templates.
* Customer-service conversation window.
* Opt-out wording.
* Quiet hours.
* Human escalation SLA.
* Staff ownership and response-time policy.
* Conversation retention.
* Attachment policy.

## AI

* OpenAI model alias.
* Provider data-processing configuration.
* Redacted trace retention.
* Per-tenant cost budget.
* Per-agent latency budget.
* Tool rate limits.
* Prompt-injection response policy.
* Agent stop and incident process.

## SaaS Self-Service

* Email confirmation policy.
* Organization naming rules.
* Slug generation rules.
* IP rate limits.
* Email rate limits.
* Duplicate account handling.
* Support recovery.
* Tenant deletion.
* Tenant export.
* Subscription boundaries.

## Roles and Fields

* Which roles can view phone numbers.
* Which roles can view transcripts.
* Which roles can view owner details.
* Which roles can view financial records.
* Which roles can view AI errors.
* Which roles can view AI cost data.
* Which roles can take or release a conversation.
* Which roles can approve price or commission overrides.

---

# UX Acceptance Criteria

Every supported operational path must meet the following criteria:

1. Primary touch targets are at least 44 by 44 CSS pixels.

2. Core mobile workflows do not require horizontal scrolling.

3. Desktop modals become appropriate full-screen or bottom-sheet flows on small screens.

4. Calendars support touch selection without requiring pointer hover.

5. Every interactive element has visible focus behavior.

6. Keyboard navigation supports the complete primary desktop workflow.

7. Arabic RTL affects:

   * Layout.
   * Navigation placement.
   * Drawers.
   * Icons with directional meaning.
   * Table alignment.
   * Date and number presentation.
   * Form flow.

8. English LTR provides equivalent functionality.

9. Every data surface includes:

   * Loading state.
   * Empty state.
   * Error state.
   * Retry action when safe.
   * Permission-denied state.

10. Destructive actions require:

* Clear labeling.
* Confirmation.
* Consequence explanation.
* Server authorization.
* Audit history.

11. Mobile navigation preserves all supported operational paths.

12. Important status information does not rely on color alone.

13. Tables collapse into cards, compact rows, or focused detail flows when required on mobile.

14. No fake data is shown as tenant data.

---

# Acceptance and Safety Gates

Each slice requires:

* Focused unit tests.
* Integration tests.
* Database tests.
* Browser tests.
* Permission tests.
* Cross-tenant tests.
* Independent security-review evidence.

The program cannot be called production-ready until Slice 0 and all enabled-slice gates pass.

---

## Slice 1 Gates

* Invitation safety.
* Membership validation.
* Multi-organization selection.
* Inactive membership denial.
* Cross-tenant denial.
* Session refresh.
* Password recovery.
* Last-owner protection.
* Protected-route cache behavior.

---

## Slice 2 Gates

* End-to-end lead-to-checkout workflow.
* Booking overlap denial.
* Owner approval enforcement.
* Deposit state authorization.
* Price-change audit.
* Commission calculation.
* Commission override authorization.
* Cancellation availability release.
* Extension history preservation.
* Staff task authorization.
* Cross-tenant property, client, booking, and payment denial.

---

## Slice 3 Gates

* Real tenant data.
* No fixture claims.
* Role-safe navigation.
* Arabic RTL.
* English LTR.
* Keyboard navigation.
* Focus behavior.
* Contrast.
* Responsive workflows.
* Touch targets.
* Loading states.
* Empty states.
* Error states.
* Permission-denied states.
* Mobile booking workflow.
* Mobile availability workflow.
* Mobile check-in/check-out workflow.

---

## Slice 4 Gates

* Signature verification.
* Wrong-tenant denial.
* Replay denial.
* Idempotent webhook processing.
* Consent enforcement.
* Opt-out enforcement.
* Conversation assignment.
* Manual reply.
* Human takeover.
* Channel kill switch.
* Provider sandbox tests.
* Sensitive-field access denial.

---

## Slice 5 Gates

* Immutable run history.
* Tool schema validation.
* Tool authorization failure.
* Tenant isolation.
* Field-level denial.
* Stop behavior.
* Human takeover.
* Prompt-injection resistance.
* Cost limits.
* Rate limits.
* Redacted traces.
* Manual fallback.
* No unauthorized booking, pricing, payment, approval, or membership action.

---

## Slice 6 Gates

* Duplicate bootstrap safety.
* Replay-safe bootstrap.
* One new tenant only.
* No joining an existing tenant.
* Confirmation failure behavior.
* Abuse-control behavior.
* Support recovery.
* Template approval.
* Conversation-window enforcement.
* Opt-out enforcement.
* Quiet-hour enforcement.
* Delivery retry.
* Dead-letter behavior.
* Provider sandbox tests.
* Tenant-by-tenant canary.
* Kill switch.
* Alerting.

---

## Release Gates

Before production activation:

* Migration rehearsal against disposable environments.
* Migration rehearsal against preview.
* Protected-route cache-header tests.
* Token refresh tests.
* Full lint suite.
* Full build.
* Full unit and integration tests.
* Browser workflow tests.
* Dependency audit.
* Trivy or equivalent container evidence.
* Snyk or equivalent dependency evidence.
* Scanner status.
* Operational dashboards.
* Error alerts.
* Queue and delivery alerts.
* Rollback rehearsal.
* Final security review.

---

# Rollout and Rollback

All schema changes use additive or expand-contract migrations.

Migrations are deployed to preview before production.

Capabilities are independently feature-flagged by:

* Environment.
* Organization.
* User role.
* Product module.
* Agent.
* WhatsApp channel.
* External provider.
* Outbound policy.

Rollback disables the relevant feature flag and restores the prior application behavior.

Database history is forward-fixed through reviewed migrations rather than erased.

Disabling AI or WhatsApp must not block:

* Lead management.
* Client management.
* Owner management.
* Property management.
* Booking management.
* Payments recording.
* Commission tracking.
* Operational tasks.
* Cars.
* Airport transfers.
* Manual customer communication.

---

# Scope Boundary

This program does not authorize:

* Autonomous booking confirmation.
* Autonomous pricing.
* Autonomous financial decisions.
* Payment processing.
* Provider credentials.
* Production outbound WhatsApp campaigns.
* Final commission policy.
* Final approval policy.
* Public guest portal.
* Marketplace functionality.
* Microservice migration.
* Arbitrary AI tools.
* Arbitrary SQL or HTTP execution.
* Automatic production deployment.

The first executable specifications must cover:

1. **Slice 0 — Release Baseline Reconciliation**
2. **Slice 1 — Internal Identity, Organizations, and RBAC**
3. **Slice 2 — Core Operations Engine**

Slice 3 receives its implementation specification after the operational contracts and real-data workflows are approved.

Slices 4–6 receive separate designs and implementation plans after their policy, provider, staffing, privacy, and operational prerequisites are supplied.
