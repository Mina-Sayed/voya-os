# Domain rules (verified)

**Last verified:** 2026-08-05  
Only rules with implementation and/or SQL/test evidence. Open product policy is marked **open**, not invented.

## Tenancy

1. **Organization is the tenant root.** Almost all business rows carry `organization_id`.
2. **Child relations are tenant-qualified.** FKs use `(organization_id, id)` pairs so a child in org A cannot reference a parent in org B (strengthened further in production security remediation).
3. **Active membership required.** Commands/helpers check `organization_memberships` for `user_id = auth.uid()` and `status = 'active'`.
4. **Client cannot choose actor identity.** Membership and org come from server session + validated cookie selection among *that user's* memberships (`voya-organization-id`).
5. **Checkout/application rule:** no self-service org bootstrap is exposed in
   this checkout's application code. Managed Supabase separately contains
   `public.bootstrap_personal_workspace(uuid)`; its deployment and product
   policy alignment remain open (see [CURRENT_STATE.md](./CURRENT_STATE.md)).

6. **Authentication rate-limit rule:** the canonical checkout contract is
   `consume_auth_rate_limit(text, text)`, with limits selected by the database
   (`magic_link = 5/900`, `password_sign_in = 10/900`). The local rolling
   compatibility candidate accepts the legacy four-argument signature only
   with those exact values and rejects `password_sign_up`; the managed overload
   remains unverified after repair until an approved apply window.

## Roles (application)

Stable role set: `owner | manager | sales_agent | operations | accountant | viewer`.

Authorization is **layered**:

1. Page gate: `requireWorkspaceMembership(allowedRoles?)`
2. Nav filter: `workspaceNavigationItems.allowedRoles`
3. Action gate: role sets in Server Actions where needed
4. **Authoritative:** role checks inside SECURITY DEFINER RPCs

UI hiding is never sufficient.

Representative verified gates:

| Capability | Typical allowed roles (code/RPC) |
|---|---|
| Leads workspace | owner, manager, sales_agent |
| Booking draft / lifecycle UI | owner, manager, sales_agent, operations |
| Decide booking approval | owner, manager (and not same as requester) |
| Confirm booking | owner, manager, sales_agent, operations (requires prior approval) |
| Stay check-in/out | owner, manager, operations |
| Operations tasks | owner, manager, operations |
| Transport create request | owner, manager, sales_agent, operations |
| Fleet vehicle/driver + assign | owner, manager, operations |
| WhatsApp channel create | owner, manager |
| AI center | owner, manager, sales_agent, operations, accountant (finance agent still disabled) |

Exact sets differ per RPC — always read the function body for the command you change.

## Stay / date semantics

- Stays and blocks use **half-open** ranges: `[check_in, check_out)` / `[start_date, end_date)`.
- Adjacent ranges are allowed; overlaps are not for conflicting occupancy sources.
- Domain helper: `src/domain/bookings/stay-range.ts`.
- Confirmed booking overlap helper (non-authoritative precheck): `hasConfirmedBookingConflict`.

## Booking lifecycle

Statuses on `bookings.status`:

`draft → pending_approval → confirmed → completed`  
also `cancelled` exists in schema; **cancellation command/policy is not implemented** as a full business workflow.

Verified transitions (ADR-008 + lifecycle RPCs, hardened in ADR-013):

| From | Command | To | Notes |
|---|---|---|---|
| (create) | `create_booking_draft` | `draft` | idempotent key; tenant FKs |
| `draft` | `request_booking_approval` | `pending_approval` | snapshot hash; 24h expiry baseline |
| `pending_approval` | `decide_booking_approval` reject | `draft` | maker ≠ checker |
| `pending_approval` | `decide_booking_approval` approve | stays pending until confirm | decision recorded |
| `pending_approval` + approved unexpired | `confirm_booking` | `confirmed` | consumes approval → `executed` |
| `confirmed` | `record_booking_stay_event` check_in | still confirmed | one check-in |
| `confirmed` + check_in | `record_booking_stay_event` check_out | `completed` | requires prior check-in |

Invariants:

- Confirmation requires **approved, unexpired** approval matching booking snapshot rules (ADR-013 tightens expiry and locking).
- Requester cannot approve their own booking.
- Idempotency keys required for lifecycle commands; booking command idempotency table binds key to org/command/booking where migrated.
- Successful transitions write **audit** (+ **outbox** events for key lifecycle points).
- No prices, deposits, refunds, or commissions in these commands.

## Occupancy

1. Confirmed bookings cannot overlap on same `(organization_id, property_id)` — GiST exclusion on `bookings`.
2. Confirmed bookings also cannot overlap **availability blocks** — unified `property_occupancies` ledger with GiST exclusion (ADR-002).
3. Application checks improve UX; **database wins** under concurrency.

## Property / availability

- Properties are independently bookable units (`code` unique per org).
- Status `active | inactive`; inactive properties cannot take new confirmable paths (checked in lifecycle commands).
- Availability blocks are operational closures over half-open date ranges.
- Property owners are CRM-like party records with ownership periods.

## Approvals (generic foundation + booking use)

- `approval_requests` store immutable proposal snapshot + sha256 hash.
- Statuses include pending/approved/rejected/expired/cancelled/executed.
- Booking uses `proposed_action = 'booking.confirm'`.
- Separation of duties: decide path rejects same membership as requester.
- Approval does **not** waive occupancy constraints.

## Operations tasks

- Tenant-scoped task registry with status transitions enforced in RPC.
- Terminal states must not reopen casually (hardened in production security remediation).

## Transport / fleet

- Vehicles, drivers, transport requests are tenant-scoped.
- Active assignment occupies `[pickup_at, return_at)` while status is `assigned` or `in_progress` (null end treated conservatively unbounded) — GiST exclusion (ADR-013).
- `completed` / `cancelled` release resources.
- Forward-only status machine in command RPCs.

## WhatsApp / CRM

- Staff inbox stores provider-neutral message facts.
- Inbound webhook is signature-verified and service-role only.
- Internal notes follow assignment/owner-manager style authorization (hardened).
- Outbound WhatsApp and AI auto-replies require explicit enable flags + human-handoff approval (default off).

## AI

- Agent kinds: `sales | booking | finance | manager`.
- Finance agent mode is **disabled** until finance policy exists.
- Allowed tools today are **read/proposal only** (`search_properties_v1`, `check_availability_v1`) via `src/domain/ai/tool-policy.ts`.
- Models must not receive arbitrary HTTP, SQL, credentials, or source-record mutation tools.
- Run requests are recorded via `create_ai_run_request` RPC; any checkout
  provider call is gated by Gemini runtime flags, with managed execution
  requiring separate provider evidence.

## MFA

- Workspace requires verified TOTP factor **and** session AAL2 (`src/domain/auth/mfa-policy.ts`).
- No factor → enrollment; factor but AAL1 → challenge.

## Localization

- Default locale `ar` with RTL; `en` supported in profile/org defaults.
- Storage values remain canonical; presentation localizes.

## Open decisions (do not invent)

- Cancellation / reconfirmation financial effects
- Pricing, deposits, payments, commissions, settlements, tax
- Full field-level permission matrix finalization
- Notification external channel providers
- Outbox worker hosting and dead-letter ops policy
- Property building/unit hierarchy beyond single bookable property
