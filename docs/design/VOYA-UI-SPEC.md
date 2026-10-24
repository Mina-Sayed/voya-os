# VOYA Stay — UI Specification

**Status:** Homepage visual design accepted; VOYA Stay V1 request flow implemented on the feature branch. Live organization/content configuration and managed rollout remain gated.
**Truth plane:** Branch-only checkout implementation; no managed migration, Storage policy, organization mapping, or public content apply is verified.
**Reference source:** `voya-ui-reference-pack/voya-ui-reference/` (the requested `design/reference/voya-ui-reference/` path is not present in this checkout).
**Audience:** People exploring furnished stays in Egypt.
**Public site job:** Introduce VOYA Stay, surface only staff-approved stays, accept a request for staff review, and keep illustrative content out of the live catalog.

## Product and architecture boundary

VOYA Stay is a public customer-facing surface in the existing Next.js modular monolith. `/` preserves the Supabase callback bridge and otherwise renders the public homepage. `/stay/search` and `/stay/property/[slug]` read only the new one-organization public projection. Owner/manager AAL2 commands publish explicitly selected active properties and metadata-stripped image derivatives. A bounded same-origin request handler creates a consented CRM lead for review in `/workspace/leads`; it does not create a booking, hold occupancy, or collect payment. The homepage search uses a GET request containing destination, dates, and party size. Those criteria are not personal contact data.

Keep staff pages under `/workspace` with their current membership, MFA, and role checks; the public shell does not reuse or replace `WorkspaceShell`. The singleton storefront starts disabled and unassigned. Search, detail, privacy-notice, and request reads fail closed when the required configuration or service role is unavailable. The `VOYA_STAY_DEMO_MODE=1` content path is local/test only and is disabled in production.

The public projection contains approved title/copy/area/capacity/amenities and opaque derivative paths. It contains no price, exact address, private property IDs, original image paths, owner data, operations notes, or reviews. Projection tables have no browser grants; public route handlers use fixed-output service-role RPCs. Public derivatives live in a dedicated public bucket with restrictive browser write policies; original `property-images` objects stay private. The nonce-based browser CSP permits `img-src` from the configured Supabase origin to render only the server-selected derivative URLs. Requests store HMAC fingerprints for the database-owned contact rate limit, privacy consent version/time, and an idempotency binding. A provider edge rate limit and approved retention/privacy inputs remain production release gates.

## Visual direction

The page is a calm Egyptian hospitality welcome: a wide, atmospheric apartment image introduces the stay experience; a short Arabic headline and two-tier CTA sit over the image; a warm, floating search panel bridges the hero and a quiet benefit row. Below it, an editorial accommodation gallery leads into emerald service-concept panels, a clear three-step search explainer, an honest support-state panel, and a premium footer. The visual signature remains the image-and-search overlap; the lower sections extend the same restrained language without making the page feel like a product dashboard.

| Role | Value | Source and use |
|---|---|---|
| Night harbor | `#153B34` | Existing `--harbor`; primary actions and hero contrast |
| Emerald | `#1A6958` | Existing `--tide`; secondary emphasis |
| Limestone | `#F3EFE6` | Existing `--canvas`; page background |
| Soft white | `#FBFAF7` | Existing `--surface`; header and form surface |
| Ink | `#172A28` | Existing `--ink`; primary text |
| Sea glass | `#D5E9DF` | Existing `--sea-glass`; quiet accents and focus |
| Neutral line | `#D9DFD8` | Existing `--line`; fine separators |

These values already exist in `src/app/globals.css`; that stylesheet remains the runtime token source. The public page may add scoped layout/elevation rules but must not fork palette values. The existing Arabic face is Noto Kufi Arabic and the existing utility face is Geist Mono. Keep the VOYA wordmark in a neutral Latin sans stack already available at runtime.

### Type, space, shape, and elevation

- Arabic page title: responsive 36–64px, weight 700–800, line-height 1.2–1.35; use a short two-line statement on desktop and avoid clipping on narrow screens.
- Section titles: 22–30px, weight 700; body: 14–17px with 1.7–1.9 line-height; field labels and helper copy: 12–14px.
- Use an 8px-led rhythm: 8, 12, 16, 24, 32, 48, 64, 80px. Page gutters are 20–24px on phones and 40–64px on desktop.
- Content maximum width: 1320px. Header content and hero search align to the same centered grid.
- Controls: minimum 44px target height. Search panel and major cards use 16–22px radii; small controls use 10–14px; primary buttons may be pill-shaped.
- Use one soft, broad shadow for the search panel and small restrained elevation for floating controls. Borders stay thin and neutral; avoid stacked card-on-card surfaces.
- Motion is limited to short hover/focus transitions. Respect `prefers-reduced-motion` already handled globally.

## Page and interaction inventory

| Screen / milestone | Visual structure | Interaction and boundary |
|---|---|---|
| Public homepage — current | VOYA Stay header; image-led hero; functional destination/date/guest search; dynamic featured published stays or clearly labeled illustrative cards when the public catalog is empty; service concepts; review steps; trust/support state; footer. | Search is GET and contains no guest contact data. Featured cards use the approved public projection. Service cards remain illustrative until approved services exist. Request/support copy reflects the disabled-by-default request configuration. |
| Public search — current | Responsive result cards with area, approved copy, selected public image derivatives, capacity, and advisory date status. | Calls a no-organization-ID service-role RPC. Does not show price, ratings, exact addresses, or occupancy records. Local design examples appear only with the explicit development/test demo flag. |
| Public property detail — current | Breadcrumb, public derivative image, approved facts/amenities, availability notice, and request form when request configuration is valid. | Form requires a phone or email, dates, party size, and privacy consent. It submits to `/api/stay/requests`; receipt says review is pending. No booking action is exposed. |
| Staff publication — current | Public title/copy/area/capacity/amenities form, explicit private-image checkboxes, publication status, and unpublish action inside the property directory. A pending-cleanup retry appears after an unpublish/deactivation cleanup failure. | Owner/manager AAL2 commands enforce configured organization and property/image ownership. Operations may retry only a tenant-verified cleanup queue; they cannot publish. |
| CRM request review — current | Existing lead cards show the requested public property and consent version/timestamp for `voya_stay` leads. | Uses the existing CRM follow-up/client-conversion path. Booking remains a separate staff-reviewed action. |
| Customer reservations — later | Authenticated customer reservation list with clear status and detail links. | Guest identity and ownership model are not implemented; do not reuse staff membership access or weaken staff MFA. |
| VOYA Partners — future | Separate owner portal with its own information architecture. | Later product decision; do not change internal workspace screens to match the collage. |
| VOYA OS internal dashboard | Existing protected operational shell and dashboard. | Preserve the current implementation, permissions, and visual identity. |

### V1 component inventory

| Component | Responsibility | Runtime boundary |
|---|---|---|
| `VoyaStayHomePage` | Server-rendered public composition for the complete homepage. | `src/features/stay/`; no membership or tenant lookup |
| `StayHeader` | Brand wordmark, section navigation, sign-in link, responsive disclosure. | Semantic links; navigation stays inside the public page or uses existing auth route |
| `StaySiteFrame` | Shared public header, skip link, main landmark, and footer across VOYA Stay routes. | Explicit `home`, `search`, or `detail` navigation destinations; no workspace membership lookup |
| `StayHero` | Responsive `next/image`, contrast overlay, headline, two-level CTA, illustrative-media label. | The decorative hero image is local; live search criteria are sent by same-site GET. |
| `StaySearchForm` | Destination, native date fields, guest selection, accessible validation. | GET to `/stay/search`; only search criteria, never guest contact data. |
| `StayBenefits` | Three short, non-operational product principles below the search panel. | Static, accurate Arabic copy; no service/provider guarantees |
| `SectionHeading` | Reusable eyebrow, heading, and supporting copy for content sections. | Static server component; supports light and dark surfaces |
| `StayConceptCard` | Reusable static illustration card for the local design example mode. | Never used as live inventory. |
| `StayPublicListingCard` | Approved public listing image, title, copy, area, capacity, and advisory status. | Receives projection data only; no internal IDs or price. |
| `FeaturedStaysSection` | Featured projection cards or clearly labeled illustrative fallback. | Loaded by a service-role catalog RPC; fallback is only dev/test gated. |
| `StayLiveSearchPage` | Search summary, published result grid, advisory copy, and empty/invalid states. | Uses strict query parsing and the public projection adapter. |
| `StayLivePropertyDetailPage` | Approved property detail and optional request form. | No booking/availability guarantee; requests are hidden when request config is not ready. |
| `StayGuestRequestForm` | Contact/date/party/consent form and receipt state. | Same-origin API POST with idempotency key, bot trap, no browser database writes. |
| `StaySearchExamplesPage` / `StayPropertyDetailPage` | Local illustrative examples retained for visual QA. | Render only under explicit dev/test mode; never in production. |
| `StayDemoGallery` | Accessible thumbnail selection over illustrative photos. | Local client state changes the displayed example image only |
| `ServicesSection` | Airport transfer and chauffeur concept panels. | Clearly marked design concepts; no offer, provider, or booking action |
| `HowItWorksSection` | Three steps, with request availability copy derived from server configuration. | Clearly distinguishes request review from booking. |
| `SupportSection` | Trust notes and request-enabled/disabled state. | No unapproved phone, WhatsApp, or email channel is invented. |
| `StayFooter` | VOYA identity, public navigation, team sign-in, and no-auto-booking disclosure. | No external support claim. |

The checkout currently has no general shared public-site component library. Reuse the existing color/font tokens, Next.js App Router, `next/image`, Lucide icons, and semantic patterns. Do not reuse the role-filtered staff shell or its navigation as customer-facing chrome.

The search form uses the browser-owned native date picker and guest `<select>` popup. Date values remain ISO `YYYY-MM-DD`; URL criteria are validated before calling the catalog RPC. The guest request form uses explicit labels, at-least-one-contact validation, a required privacy consent, honeypot, same-origin POST, and receipt-only state.

## Arabic and responsive rules

- Keep document `lang="ar"` and `dir="rtl"` from the root layout. Set local direction explicitly only for known mixed-direction values.
- Use logical CSS properties (`margin-inline`, `padding-inline`, `inset-inline`, `text-align: start`) so layout remains RTL-safe.
- Put dates, counts, and Latin identifiers in small `dir="ltr"` / bidi-isolated spans when their reading order could be ambiguous. Stored form dates remain ISO values.
- Keep Arabic copy short enough to wrap naturally; never copy the generated glyphs or malformed text from the raster references.
- Desktop navigation is inline; at narrow widths it becomes a disclosure. Search changes from a single horizontal row to labeled fields, a full-width guest selector, and a full-width action. Accommodation cards stack at phone widths; service concepts and support adapt without horizontal scrolling.
- Check at 360, 390, 768, 1024, and 1440px. Avoid horizontal overflow and preserve natural page scrolling.
- Preserve visible focus, native keyboard operation, clear field labels, associated validation/help copy, and an `aria-live` status. Decorative icons are hidden from assistive technology.

## Milestones and Done criteria

1. **Homepage (visual approval received):** responsive public homepage and root callback bridge remain intact; search now directs to the published catalog.
2. **Public search/detail:** list and detail use the allowlisted single-organization projection and advisory occupancy boolean. Local examples are gated to dev/test.
3. **Staff publication/media:** owner/manager AAL2 publication with explicit copy/image selection, derivative upload, rollback, unpublish, cleanup, and automatic hide/cleanup when a property becomes inactive.
4. **Guest request/CRM review:** same-origin bounded POST, contact+payload HMAC, consent version/time, idempotency/rate limit, CRM lead, and existing staff review/conversion workflow.
5. **Local proof:** SQL grant/isolation tests, focused unit tests, public and authenticated browser flows, and local build/lint/type checks. Managed rollout and deployment remain out of scope.
6. **Customer reservations and VOYA Partners:** separate future decisions; no guest account portal or marketplace is introduced.

## Known risks and open decisions

- **High release gate:** The singleton organization, approved public facts/photos, privacy notice/version, CRM retention, support copy, request HMAC secret, and independently verified edge rate limit must be provisioned before enabling production requests. `VOYA_STAY_EDGE_RATE_LIMIT_ENABLED=1` is only an acknowledgment after that review.
- **High:** Existing bookings require staff authorization, approval, idempotency, audit, commercial completion, and database occupancy checks. A public request is not a booking confirmation and must not bypass those controls.
- **High:** Only transformed, explicitly approved WebP derivatives may enter the public bucket. Original photos remain private; CDN/browser caches may keep a removed derivative until its cache lifetime expires.
- **Medium:** `/` preserves the `/auth/callback` bridge and otherwise renders VOYA Stay; staff navigation remains under `/workspace`.
- **Medium:** The reference collage has fictional data and generated copy, so this spec follows its hierarchy and palette but not its business claims or exact glyphs.
- **Unknown — managed:** Migration, Storage RLS policy, bucket access, environment variables, and edge rate-limit state have not been applied or verified in a managed environment.
- **Out of V1:** Public prices/reviews, instant booking, confirmation, inventory holds, payment, customer accounts, and booking portal.
