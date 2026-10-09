# Domain rules (verified)

**Verified — checkout/local integration, 2026-10-07:** `fix/release-integration-20261007` combines develop `e72a5f0` (PR #79), PR #77 `bc13fb9`, and PR #76 `511e2ae`. Combined source/schema checks and limitations are recorded in [CURRENT_STATE](CURRENT_STATE.md). No managed deployment is inferred.

**Last verified:** 2026-10-01 (checkout remediation)
Only rules with implementation and/or SQL/test evidence. Open product policy is marked **open**, not invented.

## Tenancy

1. **Organization is the tenant root.** Almost all business rows carry `organization_id`.
2. **Child relations are tenant-qualified.** FKs use `(organization_id, id)` pairs so a child in org A cannot reference a parent in org B (strengthened further in production security remediation).
3. **Active membership required.** Commands/helpers check `organization_memberships` for `user_id = auth.uid()` and `status = 'active'`.
4. **Client cannot choose actor identity.** Membership and org come from server session + validated cookie selection among *that user's* memberships (`voya-organization-id`).
5. **Self-service organization eligibility:** `create_organization` and the legacy `bootstrap_personal_workspace` require an AAL2 session and no prior membership of any status. Only `accept_organization_invitation` is an intentional AAL1 pre-workspace command.

6. **Authentication rate-limit rule:** `consume_auth_rate_limit(text, text)`
   selects budgets in the database. The integration carries PR #79's source-wide,
   source-independent account, and source/account tiers for sign-in, sign-up,
   password reset and invitation resend. Historical rolling compatibility
   signatures are not permission to choose caller-defined limits. Managed
   overloads, grants, policy and trusted-proxy configuration require separate
   verification; see SECURITY and INTEGRATIONS.

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
| Confirm booking | owner, manager only (requires prior approval + complete commercial amount/currency snapshot; legacy path included) |
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

## Money and timezone contracts

- Supported currencies and their minor-unit scales are an explicit contract in
  `src/domain/money/currency.ts` and `public.supported_currency_contract`;
  unknown three-letter codes do not receive a default scale.
- Booking minor amounts remain exact integer snapshots. Property prices retain
  their stored major-unit values; the forward migration only widens the column
  scale for the supported three-decimal currencies and never rescales history.
- Organization and property timezone values are restricted to the explicit
  intersection contract in `src/domain/time/timezone-contract.ts` and
  `public.supported_timezone_contract`. PostgreSQL aliases that the Node
  runtime cannot render (for example `Factory`) are rejected.
- Existing historical values are not rewritten by the contract migration. A
  recovery edit must explicitly replace an unsupported currency/timezone with a
  supported value.

## Booking lifecycle

Statuses on `bookings.status`:

`draft → pending_approval → confirmed → checked_in → checked_out → completed`
Draft cancellation and maker-checker cancellation commands exist; cancellation financial effects remain open product policy.

Verified transitions (ADR-008 + lifecycle RPCs, hardened in ADR-013):

| From | Command | To | Notes |
|---|---|---|---|
| (create) | `create_booking_draft` | `draft` | idempotent key; tenant FKs |
| `draft` | `request_booking_approval` | `pending_approval` | snapshot hash; 24h expiry baseline |
| `pending_approval` | `decide_booking_approval` reject | `draft` | maker ≠ checker |
| `pending_approval` | `decide_booking_approval` approve | stays pending until confirm | decision recorded |
| `pending_approval` + approved unexpired | `confirm_booking` | `confirmed` | consumes approval → `executed` |
| `confirmed` | `record_commercial_booking_stay_event` check_in | `checked_in` | one check-in |
| `checked_in` | `record_commercial_booking_stay_event` check_out | `checked_out` | requires prior check-in |
| `confirmed` + check_in | legacy `record_booking_stay_event` check_out | `completed` | requires prior check-in |

Invariants:

- Confirmation requires **approved, unexpired** approval matching booking snapshot rules (ADR-013 tightens expiry and locking).
- Every new write resulting in `confirmed`, `checked_in`, `checked_out`, or `completed` requires `commercial_completion_status = 'complete'`, an exact non-null minor-unit amount, and a non-null currency. New stay events enforce the same tenant-qualified booking snapshot guard.
- `complete_booking_commercial_snapshot` is a draft-only, idempotent completion command. Confirmed or later rows use the approved amendment flow where applicable. Its payload identity includes amount, currency, and reason; legacy keys whose original payload cannot be reconstructed fail closed.
- Legacy `request_booking_approval` and `confirm_booking` require a workspace AAL2 JWT at the database boundary; stale active approval snapshots are cancelled and replaced on a new request key, while each approval idempotency key remains bound to its resulting request.
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
- V1 property status is `active | inactive | archived`; archived properties are retained and cannot enter new ownership/image/booking paths.
- Property edits, archive, and restore use optimistic `version` plus organization-scoped idempotency; there is no hard-delete path.
- Inventory fields may remain null when the user has not supplied a fact; the UI must say incomplete rather than inventing values.
- Availability blocks are operational closures over half-open date ranges.
- Property owners are tenant-scoped party records with phone/WhatsApp/email, preferred contact method, notes, status, and version. Their V1 edit/archive/restore commands are role-gated and audited.
- Ownership periods are half-open, tenant-qualified, and exclusion-protected. New assignments require an active owner and an unarchived property; the database wins under concurrent overlap.
- Property images use a private storage boundary: only JPEG/PNG/WebP, at most 10 MiB each and 20 active images per property; metadata registration and signed retrieval require tenant membership. Public URLs are not a product contract.

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
- Fleet vehicle/driver creation (`create_fleet_vehicle_v1` / `create_fleet_driver_v1`) requires an organization-scoped idempotency key; a repeated submit with the same key and payload returns the same row without duplicate audit/outbox, while the same key with different data raises `23505` (K-045 hardening).
- Active assignment occupies `[pickup_at, return_at)` while status is `assigned` or `in_progress` (null end treated conservatively unbounded) — GiST exclusion (ADR-013).
- `completed` / `cancelled` release resources.
- Forward-only status machine in command RPCs.

## WhatsApp / CRM

- Staff inbox stores provider-neutral message facts.
- CRM V1 leads require a name and at least one submitted contact method; phone/email normalization is for duplicate warnings only.
- Lead statuses are fixed to `new | contacted | qualified | offered | won | lost` in V1 commands. Legacy `converted` is read/migrated as `won`.
- Lead activities are append-only evidence. Follow-ups are human work items with explicit due time and completion; no external message is sent automatically.
- Duplicate warnings do not merge or overwrite records. Lead-to-client conversion is atomic, idempotent, tenant-scoped, and records a conversion activity, audit event, and outbox event.
- Sales-agent lead update/archive/convert RPCs lock and check the target lead's current assignment before replay or mutation. Lead reassignment requires owner/manager authorization. CRM retries bind the original request hash, resource, and result.
- Workspace booking confirmation, stay-event, and client-list RPCs repeat the AAL2 gate in PostgreSQL. Confirmation/stay-event idempotency keys cannot be replayed against another booking, event type, or notes payload.
- Inbound webhook is signature-verified and service-role only.
- Internal notes follow assignment/owner-manager style authorization (hardened).
- Outbound WhatsApp and AI auto-replies require explicit enable flags + human-handoff approval (default off).

## AI

- Agent kinds: `copilot | sales | booking | finance | manager`.
- The read-only Copilot is available to `owner | manager | sales_agent | operations` and may only read an organization-scoped operational summary; it proposes reviewable priorities and cannot execute source-record mutations. Property aggregates remain organization-wide; sales agents see only unassigned or self-created booking/lead facts and receive `null` for operations-task context because that role has no task-read permission. Operations task counts are limited to unassigned or self-assigned work, while owner/manager counts remain organization-wide; `null` is distinct from zero tasks.
- Finance agent mode is **disabled** until finance policy exists.
- Allowed tools today are **read/proposal only** (`read_copilot_context_v1`, `search_properties_v1`, `check_availability_v1`) via `src/domain/ai/tool-policy.ts`; grants remain agent- and role-specific rather than every agent receiving every tool.
- Models must not receive arbitrary HTTP, SQL, credentials, or source-record mutation tools.
- WhatsApp AI stores extracted state as a conversation proposal. Low-confidence facts are not projected into CRM; higher-confidence data may fill blank fields but cannot replace established facts. Automatically created WhatsApp leads are visibly marked unverified until a human edits them.
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

## Review remediation — 2026-10-01 checkout

- Self-service organization creation requires a verified AAL2 session and no prior membership row of any status; accounts with suspended memberships return to the access-pending path. Accepting a pending invitation remains a pre-workspace AAL1 flow, but cannot replace an already-active membership's role.
- Booking command keys stay bound across lifecycle transitions. Changed booking/event facts with a reused key conflict; exact replays return the original booking or stay event.
- Expired booking approvals expose a fresh request action through the existing maker-checker command. The dashboard preview includes only pending work and its count is computed independently of the four-row preview limit.
- A terminal outbox failure updates the delivery or WhatsApp AI run state atomically with the leased event; transient failures remain retryable without marking delivery failed.
- Lead edits preserve the existing assignee, sales commands enforce assignment scope, and CRM command keys reject changed-payload replays. Activity and follow-up times render using the organization's timezone.
- Transport status controls are shown only to roles authorized by the matching server action.

These are checkout facts proved by focused SQL and unit tests; managed deployment and provider state remain unknown.

## WhatsApp partial property correction — 2026-10-05

**Verified — checkout only:** a partially applied WhatsApp confirmation may correct
property facts only while the original property command has no committed row.
Applied owner/ownership facts, record IDs, and command keys remain bound to
the accepted attempt; the preceding recovery migration permits edits to other
uncreated sections. Recovery first checks the tenant-scoped property idempotency
key to restore a committed result whose response was lost. Once the property
exists, the accepted property payload remains immutable. Both property-create
overloads serialize WhatsApp commands on the conversation lock and reject
superseded property facts from an older in-flight Action. Evidence:
`20261004010100_whatsapp_confirmation_payload_recovery.sql`,
`20261005001314_whatsapp_partial_property_correction.sql`, and
`whatsapp_confirmation_correction.sql`. Managed apply remains unknown.
