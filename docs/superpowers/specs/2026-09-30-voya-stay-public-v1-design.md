# VOYA Stay public V1 — architecture specification

**Status:** Approved for implementation by the user on 2026-09-30

**Truth plane:** Checkout candidate; no managed deployment or migration apply is implied.

**Scope:** One designated VOYA organization; explicitly published stays; public search/detail; request-only guest intake into CRM.

## User flow

1. An owner or manager reviews a property and selects the public title, copy,
   public-area label, capacity facts, amenities, and specific images to publish.
2. VOYA Stay exposes only that projection and its approved image derivatives.
3. A guest searches published stays by area, dates, and party size. Any date
   result is advisory; this search and a submitted request do not reserve or
   confirm inventory.
4. A guest submits a contact method, requested dates/party, and consent to be
   contacted under the configured privacy-notice version.
5. The server creates an idempotent CRM lead with source `voya_stay`. Staff
   review it in `/workspace/leads`, contact the guest, and continue through the
   existing client conversion and booking approval workflows when appropriate.

## Data and trust boundaries

- `voya_stay_storefront_config` is a singleton, DB-admin provisioned
  mapping. It starts disabled and unassigned. Client input never selects the
  tenant. No row means no public results and no accepted requests.
- `voya_stay_public_listings` is a separate allowlisted projection linked to
  internal properties by tenant-qualified foreign keys. It has no price,
  exact address, unit label, owner contact, operational notes, or booking facts.
  It has no direct `anon`/`authenticated` table grants. Public server reads use a
  narrowly granted service-role RPC that returns only the approved projection
  for published rows and derives the organization from singleton config.
- `voya_stay_public_listing_images` refers to transformed derivatives in a
  separate public `voya-stay-public-media` bucket. The original private images
  are unchanged. Derivatives are re-encoded to WebP to strip metadata; only
  explicitly selected derivatives are uploaded. Public bucket reads are
  intentional; restrictive Storage RLS policies deny browser insert/update/delete
  even if another permissive policy is later added. Uploads/deletes use the
  server-only service role, and unpublish removes derived objects after hiding
  the listing metadata. Deactivating/archiving a property also unpublishes it,
  removes derivative metadata, and queues its derived files for cleanup.
- Staff publish/unpublish commands require an active membership, AAL2, and
  owner/manager role; the database independently verifies the configured
  organization, active property, and valid source images. Direct table writes
  remain denied. Operations staff may read publication cleanup state and retry
  queued derivative deletion, but cannot publish or unpublish.
- The public catalog query exposes no organization/property IDs. Public RPC
  access is bounded by explicit `EXECUTE` grants to `service_role` (not by a
  request-claim GUC check). Availability
  checks use the existing occupancy ledger and return only an advisory
  available/unavailable result for a public slug and date range. Public reads
  and availability checks use fixed-output service-role-only RPCs, not direct
  access to operational tables.
- `POST /api/stay/requests` accepts only bounded contact, listing, date, party,
  consent, and idempotency fields. It ignores tenant IDs. The server validates
  same-origin, bounded body size, honeypot, normalized contact, fixed HMAC rate
  limit, current consent version, published listing, and valid dates before invoking a
  service-role-only CRM capture RPC.
- The capture RPC writes a `leads` row plus audit/outbox evidence in one
  transaction. It does not write `bookings`, `property_occupancies`, approvals,
  payments, or confirmations. Retries with identical idempotency payloads
  return the existing lead; changed payloads fail closed.

## Runtime behavior and failure handling

- An unconfigured storefront or privacy/rate-limit configuration disables
  publication/request acceptance rather than exposing a fallback dataset.
- `VOYA_STAY_REQUEST_HMAC_SECRET` (at least 32 bytes), the privacy notice
  URL/version, storefront organization, independently configured provider edge
  rate-limit controls, and `VOYA_STAY_EDGE_RATE_LIMIT_ENABLED=1` must be in place
  before production request capture is shown or accepted. The local dev/test
  bypass applies only to loopback/synthetic environments.
- Public search is bounded in page size, validates destination/dates/guests,
  and does not expose occupancy records or internal identifiers.
- Public request errors are generic and do not log contact data or provider
  payloads. Rate-limit/configuration failures fail closed.
- A successful request confirms only receipt for staff review. It is not an
  accepted stay, reservation, availability guarantee, or booking.
- Unpublishing hides the projection first, then removes derived public media.
  Cleanup errors are surfaced to staff; private originals remain untouched.

## Product and release boundaries

- No instant booking, payment, booking confirmation, or inventory hold in V1.
- No guest account or reservation portal in V1.
- Exact public content/images, privacy notice/version, CRM retention policy,
  support details, and the designated organization ID must be supplied before
  enabling production request capture.
- Managed Supabase grants/storage, Vercel environment, and edge rate limiting
  require separate read-only verification/configuration by the release owner.
  This implementation does not deploy or mutate managed infrastructure.

## Tests required

- SQL proofs: anon cannot access projection/operational tables or execute
  privileged functions; the service-role catalog RPC returns only published
  projection fields; unpublished/cross-tenant rows stay hidden;
  publish requires owner/manager AAL2 and designated organization; image source
  is tenant-bound; guest capture is service-role-only, idempotent, consented,
  rate-limited, and does not alter bookings or occupancy.
- Unit tests: public config fail-closed, input normalization, origin/body limit,
  HMAC bucket, media transformation/path validation, compensation on storage or
  RPC failure, and CRM mapping.
- Browser tests: staff publish → public listing/search/detail/media → submit
  request → CRM lead visible to staff; invalid dates/contact/consent, duplicate
  submit, disabled storefront, unpublish, and mobile/keyboard paths.
