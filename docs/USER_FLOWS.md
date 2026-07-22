# Voya OS User Flows

**Status:** Draft for review
**Related:** [PRD](./PRD.md), [Permissions](./PERMISSIONS.md), [AI agents](./AI_AGENTS.md)

All flows assume an authenticated user, an active organization derived from membership, server-side authorization, input validation, idempotency for retried commands, and audit coverage. Arabic RTL is the default presentation; English changes presentation, not business behavior.

## 1. Sign in and organization selection

```mermaid
flowchart TD
  A[Open Voya OS] --> B{Authenticated?}
  B -- No --> C[Sign in / complete MFA]
  C --> D{Valid active memberships?}
  B -- Yes --> D
  D -- None --> E[Access denied or invitation state]
  D -- One --> F[Select membership server-side]
  D -- Multiple --> G[Choose organization]
  G --> F
  F --> H[Load role-scoped dashboard]
  H --> I[Audit login and organization switch]
```

Edge cases: expired/revoked invitation, suspended user, stale browser tab after role change, last-owner protection, session revoked during a command, and organization ID tampering.

## 2. Create or update a property and availability

```mermaid
flowchart TD
  A[Authorized operations user] --> B[Create/edit property owner]
  B --> C[Create/edit independently bookable property]
  C --> D[Validate tenant, required fields, status]
  D --> E{Sensitive change?}
  E -- Yes --> F[Create approval request]
  F --> G{Approved and still valid?}
  G -- No --> H[Reject/expire with no effect]
  G -- Yes --> I[Apply authorized change]
  E -- No --> I
  I --> J[Add/remove manual availability block]
  J --> K[Recalculate availability view]
  K --> L[Audit and notify]
```

Edge cases: owner reassignment after historical settlements, archive with future bookings, a block overlapping a confirmed stay, concurrent edits, and removal of a block referenced by an active workflow.

## 3. Lead to client to booking proposal

```mermaid
flowchart TD
  A[Capture lead] --> B[Normalize contact fields]
  B --> C{Potential duplicate in organization?}
  C -- Yes --> D[Warn and compare; never auto-merge]
  C -- No --> E[Qualify requirements]
  D --> E
  E --> F[Search authorized available properties]
  F --> G[Prepare quote/proposal snapshot]
  G --> H{Client exists?}
  H -- No --> I[Create client and link lead]
  H -- Yes --> J[Link existing client]
  I --> K[Create draft booking]
  J --> K
  K --> L[Audit assignment, conversion, and proposal]
```

Edge cases: same person across different tenants, ambiguous phone normalization, changed price/availability after quote, missing consent, reassigned sales agent, and malicious text in lead notes.

## 4. Confirm a booking

```mermaid
sequenceDiagram
  actor User
  participant UI as Next.js UI
  participant App as Booking Application Service
  participant Policy as Authorization/Approval Policy
  participant DB as PostgreSQL
  participant Outbox as Transactional Outbox

  User->>UI: Review and submit confirmation
  UI->>App: Confirm command + idempotency key
  App->>Policy: Check tenant, role, state, approval
  Policy-->>App: Permit or deny
  App->>DB: Begin transaction and validate snapshot
  App->>DB: Set status to confirmed
  DB->>DB: Exclusion constraint checks date overlap
  alt Conflict or invalid state
    DB-->>App: Reject and roll back
    App-->>UI: Actionable localized error
  else Valid
    App->>DB: Append audit and outbox records
    App->>DB: Commit
    Outbox-->>UI: Notifications processed asynchronously
    App-->>UI: Confirmed booking
  end
```

Acceptance notes: adjacency is allowed; overlap is not. Approval never reserves inventory. The database is the final concurrency guard, and all derived effects commit atomically or not at all.

## 5. Amend or cancel a booking

```mermaid
flowchart TD
  A[Open booking] --> B[Select amendment or cancellation]
  B --> C[Show current facts and policy-dependent impacts]
  C --> D[Enter reason and proposed effective changes]
  D --> E{Approval required?}
  E -- Yes --> F[Create immutable proposal snapshot]
  F --> G[Independent eligible approver decides]
  G -- Reject/expire --> H[No booking or finance mutation]
  G -- Approve --> I[Revalidate permissions, state, policy, inventory]
  E -- No --> I
  I --> J{All checks pass?}
  J -- No --> K[No-op; explain and audit failure]
  J -- Yes --> L[Apply booking transition transactionally]
  L --> M[Create separate financial adjustments if policy requires]
  M --> N[Audit and notify]
```

Edge cases: booking changed after approval, requester or approver loses role, dates now conflict, repeated cancellation, unknown refund/commission outcome, or failure after an external provider call. Unknown financial effects must block automated execution and route to finance review.

## 6. Record and reconcile a payment

```mermaid
flowchart TD
  A[Payment event or accountant entry] --> B[Validate source, tenant, amount, currency]
  B --> C{Idempotency/source reference already exists?}
  C -- Yes --> D[Return existing result; audit duplicate]
  C -- No --> E[Create payment record]
  E --> F{Posting/adjustment needs approval?}
  F -- Yes --> G[Approval workflow]
  G --> H{Approved?}
  H -- No --> I[Remain pending/rejected]
  H -- Yes --> J[Post/reconcile through domain service]
  F -- No --> J
  J --> K[Append audit and notification outbox]
  K --> L{Correction later?}
  L -- Yes --> M[Create linked reversal/superseding record]
  L -- No --> N[Complete]
  M --> N
```

The product must not assume payment-provider behavior, allocation, fee, refund, chargeback, or exchange-rate rules before those policies are approved.

## 7. Record expense or commission proposal

```mermaid
flowchart TD
  A[Authorized user creates draft] --> B[Attach source evidence and attribution]
  B --> C[Validate amount, currency, source, duplicates]
  C --> D[Calculate only from approved versioned policy]
  D --> E[Create immutable approval snapshot]
  E --> F[Eligible approver reviews]
  F -- Reject --> G[Retain record and reason; no posting]
  F -- Approve --> H[Revalidate and post once]
  H --> I[Audit and expose for settlement selection]
  I --> J{Correction?}
  J -- Yes --> K[Reverse/supersede; never delete]
```

If no approved calculation rule exists, the system may record a human-entered proposal with provenance but must not calculate or post it automatically.

## 8. Prepare and finalize owner settlement

```mermaid
flowchart TD
  A[Accountant selects owner and period] --> B[Load eligible versioned source records]
  B --> C[Create draft snapshot and line items]
  C --> D[Show inclusions, exclusions, currency, unresolved items]
  D --> E{Policy complete and totals valid?}
  E -- No --> F[Block finalization and request resolution]
  E -- Yes --> G[Submit immutable proposal for approval]
  G --> H[Independent approver reviews snapshot]
  H -- Reject/expire --> I[Retain draft/history]
  H -- Approve --> J[Revalidate sources and consume approval once]
  J --> K[Finalize immutable settlement version]
  K --> L[Notify and audit]
  L --> M{Later correction?}
  M -- Yes --> N[Adjustment in later period or controlled reversal]
```

Edge cases: source corrected while approval is pending, multiple currencies, ownership changed mid-period, reopened period, negative balance, partial payout, and duplicate finalization.

## 9. Approval lifecycle

```mermaid
stateDiagram-v2
  [*] --> Pending
  Pending --> Approved: eligible decision(s) complete
  Pending --> Rejected: eligible approver rejects
  Pending --> Withdrawn: requester withdraws
  Pending --> Expired: deadline reached
  Pending --> Superseded: proposal changes
  Approved --> Executed: command revalidated and applied once
  Approved --> Expired: execution deadline reached
  Approved --> Superseded: target or policy invalidates snapshot
  Executed --> [*]
  Rejected --> [*]
  Withdrawn --> [*]
  Expired --> [*]
  Superseded --> [*]
```

## 10. AI-assisted workflow

```mermaid
sequenceDiagram
  actor User
  participant UI
  participant AI as AI Orchestrator
  participant Guard as Policy and Tool Gateway
  participant Domain as Domain Service
  participant DB as PostgreSQL
  participant Model as OpenAI Responses API

  User->>UI: Ask for assistance
  UI->>AI: Authenticated request in active organization
  AI->>Model: Minimized context + allowlisted tools
  Model-->>AI: Structured response/tool request
  AI->>Guard: Validate schema, budget, permission, risk
  alt Read-only permitted tool
    Guard->>Domain: Execute tenant-scoped query
    Domain->>DB: Read under policy/RLS
    DB-->>AI: Authorized result
  else Booking or financial change
    Guard->>Domain: Create proposal only
    Domain->>DB: Store proposal/approval request + audit
    DB-->>AI: Proposal ID; no source-of-record mutation
  else Denied or unsafe
    Guard-->>AI: Safe refusal/error
  end
  AI->>Model: Tool result if continuation is needed
  Model-->>UI: Labeled answer with sources/proposed effect
```

## 11. Audit review and export

```mermaid
flowchart TD
  A[Authorized user opens audit view] --> B[Server applies tenant and field policy]
  B --> C[Filter by actor, resource, action, result, date]
  C --> D[View redacted event detail]
  D --> E{Export permitted?}
  E -- No --> F[Deny and audit attempt]
  E -- Yes --> G[Create bounded export job]
  G --> H[Recheck permission before delivery]
  H --> I[Deliver expiring protected artifact]
  I --> J[Audit creation and access]
```

## 12. Global failure behavior

- Authorization failures reveal no resource existence across tenant boundaries.
- Validation and conflict errors are localized, actionable, and safe; internal details and SQL errors are not exposed.
- Retried commands are idempotent. Timeouts return an indeterminate-safe response and let the client query command status.
- External notification or AI outages degrade independently; they do not corrupt or roll back committed core records.
- Every denied sensitive action and every failed critical mutation emits security/operational telemetry with redacted context.
