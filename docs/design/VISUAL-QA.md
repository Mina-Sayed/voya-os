# VOYA Stay — Visual QA

**Status:** Homepage visual design approved. V1 live catalog/detail/request surfaces and the staff publication form were verified in local Chromium with synthetic fixtures; managed content is not configured. The saved search/detail comparisons remain explicitly illustrative demo-mode references.
**Reference source:** `voya-ui-reference-pack/voya-ui-reference/`
**Browser:** Playwright Chromium against local Next.js development, with a production build and request-time security smoke also verified. The Next.js dev toolbar was hidden only in screenshot capture after confirming no error overlay was present.

## Captures

### Before refinement

- [Desktop viewport before](../../artifacts/ui/homepage-desktop-before-visual-refinement.png)
- [Mobile viewport before](../../artifacts/ui/homepage-mobile-before-visual-refinement.png)

### Refined homepage

- [Desktop viewport — 1440×900](../../artifacts/ui/homepage-desktop-1440x900.png)
- [Mobile viewport — 390×844](../../artifacts/ui/homepage-mobile-390x844.png)
- [Full-page desktop](../../artifacts/ui/homepage-desktop-full.png)
- [Full-page mobile](../../artifacts/ui/homepage-mobile-full.png)
- [Reference vs refined desktop](../../artifacts/ui/homepage-desktop-reference-after.png)
- [Reference vs refined mobile](../../artifacts/ui/homepage-mobile-reference-after.png)
- [Before vs after desktop](../../artifacts/ui/homepage-desktop-before-after.png)
- [Before vs after mobile](../../artifacts/ui/homepage-mobile-before-after.png)
- [Feature-scoped static audit](../../artifacts/ui/voya-stay-static-audit.json)

### Search and example-detail design examples (local demo mode)

- [Search examples — desktop 1440×900](../../artifacts/ui/stay-search-desktop-1440x900.png)
- [Search examples — mobile 390×844](../../artifacts/ui/stay-search-mobile-390x844.png)
- [Search examples — full desktop](../../artifacts/ui/stay-search-desktop-full.png)
- [Search examples — full mobile](../../artifacts/ui/stay-search-mobile-full.png)
- [Search vs supplied desktop reference](../../artifacts/ui/stay-search-desktop-reference.png)
- [Search vs supplied mobile reference](../../artifacts/ui/stay-search-mobile-reference.png)
- [Example detail — desktop 1440×900](../../artifacts/ui/stay-detail-desktop-1440x900.png)
- [Example detail — mobile 390×844](../../artifacts/ui/stay-detail-mobile-390x844.png)
- [Example detail — full desktop](../../artifacts/ui/stay-detail-desktop-full.png)
- [Example detail — full mobile](../../artifacts/ui/stay-detail-mobile-full.png)
- [Example detail vs supplied desktop reference](../../artifacts/ui/stay-detail-desktop-reference.png)

The comparison images preserve each source's aspect ratio and fit both views into matching frames. The viewport captures and the reference crops have different framing and content density, so these are visual comparisons, not pixel-similarity measurements. The supplied images cover the first screen; the new lower sections are reviewed against the requested content, visual system, and mobile behavior because no matching reference crops exist for them.

## Homepage visual refinement iterations

| Pass | Review findings | Corrections |
|---|---|---|
| 1 — expanded page capture | On a 390×844 viewport the search action sat at the lower edge, the guest selector occupied only half a row, and the wide desktop service panels left too much unused space. Decorative ordinals did not carry product meaning. | Reduced the mobile hero's vertical footprint and copy spacing, made the guest selector full-width, added consistent field icons, filled service-panel balance with a restrained travel-path motif, and removed decorative numbering outside the actual three-step process. |
| 2 — refined screenshot comparison | The hero and floating search remain legible at desktop and phone widths; the primary action is fully visible on mobile. Accommodation images are distinct, cards contain no listing facts, and the full-page section transitions maintain the cream/emerald rhythm. | Kept the current hierarchy. The lower sections are explicitly treated as preview concepts, not a source for inventory, service policy, or customer-support claims. |

No critical or major visual issue remains within this homepage scope. No numeric similarity score was assigned.

## Search and example-detail reference review

The desktop search capture was compared directly with `02-desktop-search.png`, the mobile search capture with `05-mobile-listings.png`, and the illustrative detail capture with `03-desktop-property-details.png`. Each comparison is an inspection aid, not a pixel score; the supplied reference crops and full-width browser captures have different aspect ratios and content density.

| Screen | Visible difference from reference | Treatment |
|---|---|---|
| Search examples | The reference depicts a populated marketplace with a map, filters, prices, and listing facts. The local design-example page uses three editorial example cards, so it has much lower information density. | Intentional in demo mode. The live route reads only published rows and never substitutes examples in production. |
| Example detail | The reference depicts specific property facts, amenities, reviews, dates, a price, and booking actions. The VOYA Stay page instead pairs an illustrative gallery with a notice that unit facts are unavailable. | Intentional: those facts and request/booking actions are not approved or connected. The gallery supports local thumbnail selection only. |
| Mobile example detail | The supplied pack does not include a matching mobile property-detail reference crop. | Reviewed at 390×844 and full-page against the established mobile type, spacing, navigation, and color system; no unsupported property or booking facts are shown. |

The reference comparisons describe the demo-mode art direction, not the production content flow. The live route uses the same palette, typography, image geometry, RTL behavior, and disclosure styles while rendering the explicit published projection.

## Visual differences from the supplied reference

| Severity | Difference | Treatment |
|---|---|---|
| Critical | None found in the approved-color, RTL, hero/search, or responsive layout checks. | — |
| Major | The reference frames show the initial hero/search and a short benefits row; the homepage also contains service, how-it-works, support, and footer sections. | Built those sections from the same emerald/cream palette and restrained card geometry. Services remain labeled concepts; published stays come from the approved projection. |
| Minor | Original concept shows illustrative interior and destination imagery. | Used newly generated interior visuals with visible `صورة توضيحية` labels; they are not VOYA properties. |
| Minor | Reference mobile uses a bottom destination bar. | Kept a compact top disclosure and search CTA because the pictured destinations and customer portal are not implemented. |
| Minor | Native date/select popups are browser-owned. | Arabic field labels and hints are app-owned; date and guest popups retain browser-native keyboard behavior. |

No sample prices, ratings, review counts, or fake inventory were added. Demo cards are clearly labeled; live cards use only staff-approved fields. Search availability is advisory and guest requests never confirm or reserve a stay.

## Browser, responsive, and accessibility checks

- Captured viewport screenshots at 1440×900 and 390×844 plus full-page desktop and mobile views.
- Checked horizontal overflow at 360, 390, 768, 1024, and 1440px; all passed.
- Playwright verifies desktop anchor navigation, mobile disclosure navigation, visible skip-link focus, labeled form controls, empty-destination errors, invalid date order, native guest keyboard selection, GET search criteria, explicit local demo mode, and thumbnail selection by click and Space key.
- Accommodation and service concepts are static semantic articles, not click targets. Every image is labeled as illustrative and has descriptive alternative text.
- Search criteria use a same-site GET and read only the server-owned public projection; contact data stays out of the URL.
- Authenticated browser proof captures a live synthetic listing and detail page at [1440×900 search](../../artifacts/ui/voya-stay-live-search-e2e-1440x900.png) and [390×844 detail](../../artifacts/ui/voya-stay-live-detail-e2e-390x844.png).
- Authenticated browser verification found the nonce CSP blocked the configured Supabase image origin. The CSP now includes that configured origin in `img-src`; an automated browser assertion confirms the published derivative renders.
- Latest public Chromium run: `npm run test:e2e` — 10 passed. This includes the responsive homepage, public GET search, explicit local demo mode, protected workspace routing, unknown example 404, and mouse/keyboard gallery interactions.
- Playwright observed no page errors or browser console errors. The Next.js dev server emitted one non-fatal LCP hint for a lower-page illustrative image during full-page capture; that image stays lazy because it is below the initial viewport.
- `npm test`: 153 files / 759 tests pass; `npm run lint` and `npm run typecheck` pass.
- `npm run test:e2e`: 10/10 public Playwright tests passed, including the responsive homepage, form GET behavior, and demo-only image gallery.
- `npm run test:e2e:auth-local`: 22/22 tests passed against the dedicated local synthetic Supabase project using installed `/usr/bin/chromium`. Coverage includes staff publish → public search/detail/media → guest request → CRM consent/property review → unpublish and derivative deletion, plus anonymous public-bucket upload denial.
- `npm run test:db`: disposable loopback Postgres suite passed; the placeholder-config production build and `npm run test:production` passed. These are local checkout proofs; no managed Supabase or production endpoint was contacted.
- Authenticated E2E uses a test-only local font response map because outbound Google Fonts downloads timed out; production font configuration is unchanged.
- The saved [feature-scoped static audit](../../artifacts/ui/voya-stay-static-audit.json) reports 0 findings from its recorded run; it was not rerun in this final pass.

## Remaining visual limits and release gates

- The synthetic browser fixture proves the complete local interaction but does not represent an actual VOYA property or customer.
- No production organization, public photos/facts, privacy notice, CRM retention decision, support copy, HMAC secret, Storage policy application, or edge rate limit has been configured or verified.
- Prices, reviews, instant booking, payments, customer accounts, and reservations remain out of V1.
- The approved homepage visual direction is preserved. Live public content is displayed only after staff publishes an explicit projection.
