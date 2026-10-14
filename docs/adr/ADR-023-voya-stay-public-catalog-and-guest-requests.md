# ADR-023: VOYA Stay public catalog and guest requests

**Status:** Accepted for V1 checkout implementation; managed rollout is not verified

**Date:** 2026-09-30

## Context

VOYA Stay currently contains illustrative public pages only. Voya OS is a
multi-tenant furnished-rental operations workspace, not a guest marketplace.
Property reads and original images are tenant-private; bookings follow the
existing staff maker-checker and commercial-completion workflow. The approved
V1 customer flow is a guest request that staff reviews. V1 does not confirm a
booking, hold inventory, collect payment, or send automatic messages.

## Decision

- The public storefront is bound to **one explicitly designated organization**.
  Its singleton configuration starts disabled and unassigned. There is no
  fallback to all active organizations or properties.
- A dedicated public listing projection contains only staff-approved display
  content. Publishing is an explicit owner/manager AAL2 command for an active
  property in the configured storefront organization. Internal property,
  organization, owner, address, operations, and pricing facts are never returned
  by public read functions. Projection tables have no direct `anon` or
  `authenticated` table grants; public server routes call narrowly granted
  service-role RPCs that return only allowlisted projection fields.
- Approved images are transformed into a separate `voya-stay-public-media`
  public bucket. Original `property-images` objects remain private. Public
  metadata exposes only derived media URLs; unpublishing hides metadata and
  removes the public copies. Restrictive Storage policies deny browser writes
  to this bucket even under a broader permissive policy. Property inactivation
  automatically hides its listing and queues its derivatives for deletion.
  Browser `img-src` permits the configured Supabase origin so these public
  derivatives render under the existing nonce CSP. A URL may remain cached for
  the configured short cache lifetime after deletion.
- Public search filters the published projection. Date availability, where
  shown, is advisory and reveals only a boolean derived from the existing
  occupancy ledger. A guest request does not hold dates or mutate occupancy.
- A server-side public request handler applies bounded validation,
  same-origin checks, honeypot and HMAC rate limiting, consent-version
  verification, and idempotency. A narrowly granted command creates a CRM lead
  with source `voya_stay`, requested property/dates/party, and consent evidence.
  No browser Supabase write or client-supplied organization ID is accepted.
- Public and request configuration RPCs are granted explicitly to
  `service_role`; their security boundary is the narrow database EXECUTE grant.
  The implementation does not rely on an undocumented per-request JWT role GUC.
- Staff review the request in the existing CRM Leads workflow. Creating a
  client and booking remains an explicit staff action through the existing
  conversion and maker-checker booking workflows.
- Missing storefront, privacy-notice, or rate-limit configuration fails
  closed: no public listing or guest request is enabled.
- Operations staff may inspect publication-cleanup state and retry deletion of
  queued hidden/replaced derivatives through a tenant-verified server action;
  they do not receive publish/unpublish authority.
- Production request UI and capture also fail closed unless the independently
  configured provider edge limit is acknowledged by server-only
  `VOYA_STAY_EDGE_RATE_LIMIT_ENABLED=1`; local development/test environments
  use the bounded database contact limiter without claiming a managed edge rule.

## Consequences

V1 reuses the existing CRM and booking authority without introducing a guest
account portal, instant booking, payment, or a multi-organization marketplace.
The public projection and derived media are new deliberate exposure
boundaries and require SQL grant/RLS tests. Production still requires a
designated organization, approved listing content and images, a privacy notice
and retention decision, request-rate-limit secret, and provider verification.

## Alternatives considered

1. **Read `properties` or original images directly from the browser** —
   rejected because those records and objects contain tenant-private fields.
2. **Publish every active organization/property automatically** — rejected
   because the product is not a marketplace and active operational status is
   not consent to public publication.
3. **Create guest bookings or capture payments from the request form** —
   deferred; this would bypass the approved V1 staff review and requires
   separate pricing, payment, cancellation, and inventory-hold decisions.

## Verification target

Disposable database tests cover tenant/role/AAL2 denial, anonymous table and
RPC denial, service-role projection allowlisting, unpublished-property denial,
original-image privacy, idempotent guest intake, consent evidence, and absence
of booking/occupancy writes.
Browser tests cover publish → public search/detail → guest request → CRM lead
review. These are checkout proofs only and do not imply managed application.
