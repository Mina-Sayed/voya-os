# Voya OS frontend UI/UX audit

**Date:** 2026-08-11

**Scope:** Current checkout, Arabic-first RTL web interface

**Method:** Source review of all application routes and feature views, current browser verification of `/sign-in` at 1280×720 and 390×844, and review of existing local workspace screenshots.

**Evidence label:** **Verified — checkout** unless stated otherwise. This report does not claim that a managed preview or production deployment matches the checkout.

## Executive summary

Voya OS already has a recognizable product identity: the ivory, pine, sage, and brass palette fits furnished-rental operations; Arabic RTL is the default; the workspace shell is role-aware; empty states are honest; and sensitive workflows visibly communicate their limits. It does not look like a generic admin template.

The best next work is refinement, not redesign. The current UI makes many screens visually attractive but less efficient than they should be for daily operations. The main issues are the mobile sign-in order, inaccessible small/low-contrast text, incomplete mobile-navigation behavior, internal engineering terminology in user copy, and long card/form layouts that push the work queue below the fold.

| Area | Score | Summary |
|---|---:|---|
| Overall product experience | 7/10 | Strong foundation; not yet consistently efficient or accessible |
| UI quality | 8/10 | Distinctive palette, typography, iconography, and RTL composition |
| UX quality | 6/10 | Clear individual actions, but page hierarchy and long workflows create friction |
| Accessibility | 5/10 | Good semantics in many places; contrast, type size, touch targets, and mobile dialog behavior need work |
| Design-system maturity | 6/10 | Useful global tokens exist, but many one-off colors and repeated page patterns remain |
| Frontend quality | 7/10 | Thin routes and focused features; UI duplication and missing route states reduce consistency |

### Biggest strengths

- A specific hospitality-operations visual identity rather than a generic SaaS dashboard.
- Arabic-first RTL with deliberate LTR handling for emails, dates, identifiers, and codes.
- Role-filtered navigation and server-derived organization context.
- Honest empty states and clear boundaries around finance, AI, WhatsApp delivery, and permissions.
- Consistent labels, native form controls, visible pending states on many client forms, and reduced-motion support.
- Restrained motion: transitions and progress spinners support state rather than decorate the interface.

### Biggest weaknesses

- On a 390×844 viewport, the sign-in form starts below a large brand panel; the primary task is not visible on first load.
- Small text is systemic: the checkout contains 47 `10px` and 95 `11px` utility-text uses.
- Several foreground/background combinations miss WCAG AA for normal text. Examples measured from current tokens:
  - `#687b74` on `#fbfaf7`: **4.30:1**
  - `#a2742d` on `#fbfaf7`: **3.97:1**
  - `#7a8983` on white: **3.66:1**
  - white on brass `#b88a3a`: **3.12:1**
  - placeholder `#8a9891` on white: **3.01:1**
- Focus rings use pale sea-glass globally; that is visible on dark surfaces but weak on white/light surfaces.
- Mobile navigation has no active-route state, uses a 36px menu target, does not manage focus or restore focus, and declares its overlay dialog as non-modal.
- User-facing copy includes implementation words such as `provider`, `worker`, `adapter`, `command`, `server-owned`, `preview`, `sandbox`, `refunds`, and `AAL2`.
- There are no route-level `loading.tsx`, `error.tsx`, or `global-error.tsx` views.
- Creation forms are permanently expanded above lists on many pages, delaying the more frequent scan/review task.

## YAGNI decision

Keep the current visual direction. Do not start a redesign, new component library, dark mode, command palette, animation system, chart suite, or personalization layer.

The recommended sequence is:

1. Fix mobile sign-in hierarchy and accessibility defects.
2. Fix mobile navigation and plain-language copy.
3. Make operational queues list-first, with creation forms revealed only when needed.
4. Add search/filter/pagination only when a real list exceeds the agreed threshold (recommended trigger: more than 20 visible records or observed operator difficulty).
5. Consider a more action-oriented dashboard only after the team confirms which daily decisions matter most.

## Priority roadmap

No validated issue requires a new product subsystem. There are no confirmed “Critical” redesign items; the following are the highest-value improvements.

| ID | Priority | Problem and root cause | Recommended solution | User impact | Business impact | Difficulty | Estimate |
|---|---|---|---|---|---|---|---|
| H1 | High | The brand panel precedes the login task on mobile; both sign-in methods are fully expanded | On mobile, show a compact brand header followed immediately by password sign-in. Reveal magic-link sign-in through one secondary text action. Keep the expressive split panel on desktop | Faster sign-in; less scrolling and uncertainty | Fewer failed/abandoned staff sessions | Low | 0.5–1 day |
| H2 | High | Small type, low-contrast text, pale focus rings, and sub-44px targets recur across the product | Set normal supporting text to at least 12–14px, use a stronger muted color (for example `#60736c` on the light surface), use `#85652e` or darker for brass CTAs with white text, use a high-contrast focus outline, and raise interactive targets to 44px | Better readability and keyboard/touch use | Lower error rate and accessibility risk | Medium | 1–2 days |
| H3 | High | The mobile menu looks like a dialog but lacks modal behavior and route context | Add a backdrop, active item/`aria-current`, focus entry/containment/return, body-scroll lock, and a 44px trigger. Close on route change, Escape, and backdrop click | Predictable mobile navigation | Safer use during field operations | Medium | 1 day |
| H4 | High | Internal technical terminology leaks into staff-facing copy | Replace implementation language with task language. Examples: “جاهز للتجربة” instead of `preview`, “خدمة الإرسال” instead of `provider/worker`, “إجراء موثوق” only where the distinction helps, and “تحقق بخطوتين” instead of `AAL2` | Faster comprehension | Less training and support effort | Low | 0.5–1 day |
| H5 | High | Full creation forms dominate list pages, especially mobile and transport | Make the current queue/list the default focus. Use one “إضافة …” control to expand the existing inline form; do not add a new modal framework | Faster scanning and fewer accidental edits | Better daily throughput | Medium | 1–2 days across priority pages |
| M1 | Medium | Long card lists have no findability controls | When the 20-record trigger is met, add one shared, minimal toolbar: text search plus the single most useful status/date filter. Use server-scoped pagination; do not build a general query builder | Faster record retrieval | Supports growth without redesign | Medium | 1–2 days per data family |
| M2 | Medium | Some state-changing actions have weak pending/success context, and destructive transport cancellation is immediate | Keep inline feedback, move focus to it when needed, disable the active control during submission, and add a compact confirmation only for destructive/irreversible actions | More confidence and fewer double actions | Fewer operational corrections | Medium | 1–2 days |
| M3 | Medium | The dashboard emphasizes totals while its promise is to organize the operator’s day | After workflow validation, replace one generic metric area with a time-ordered “what needs attention now” rail sourced only from existing bookings, tasks, and approvals | Clearer daily priorities | Higher operational response speed | Medium–High | 2–4 days |
| M4 | Medium | A data-load failure falls through without a product-specific recovery screen | Add a small workspace error boundary with Arabic retry guidance and a route loading state for slow reads; keep technical details out of the UI | Recoverable failures | Lower support burden | Low–Medium | 1 day |
| L1 | Low | Repeated page headers, badges, empty states, status pills, and hard-coded colors drift visually | Extract primitives only when implementing two or more of the changes above. Do not begin a standalone design-system project | More consistent UI | Lower future maintenance | Medium | Opportunistic |

## UI audit

| Section | Score | What works | What to improve |
|---|---:|---|---|
| Visual hierarchy | 8/10 | Strong headings, clear primary actions, good use of pine surfaces | Large hero/header cards and always-open forms consume too much vertical space on work pages |
| Typography | 6/10 | Noto Kufi Arabic and Geist Mono are appropriate and distinctive | Widespread 10–11px text and tight tracking reduce readability |
| Color palette | 7/10 | Memorable and product-appropriate | Several current combinations fail AA; brass should not carry small white text at its current value |
| Spacing | 7/10 | Comfortable spacing and clear grouping | Desktop pages can feel sparse; mobile pages can become long because every group is a large card |
| Grid/layout | 7/10 | Responsive grids collapse cleanly | Card grids are used where denser operational lists would scan faster |
| Icons | 8/10 | Lucide icons are consistent and usually decorative icons are hidden from assistive tech | Some icon-only controls are too small or rely on tooltip/title behavior |
| Cards | 6/10 | Attractive and consistent surfaces | Too many nested rounded cards reduce information density and make all content feel equally important |
| Buttons | 6/10 | Action labels are generally specific | Some targets are 36–40px; destructive/state-transition actions need stronger feedback and confirmation rules |
| Forms | 7/10 | Labels are associated, inputs are comfortably sized, server results are announced in many forms | Forms dominate list pages; sign-in has two complete forms; password reveal and clearer field-level validation would help |
| Tables/lists | 6/10 | Dashboard table supports RTL and horizontal overflow | Most operational registries have no search, filter, sort, or pagination; desktop card layouts scan slowly at volume |
| Charts | Not needed | Avoiding decorative charts is correct for the current data | Add none until a specific decision requires a trend visualization |
| Dialogs | 5/10 | Escape closes mobile navigation | Focus management, modality, backdrop, and focus restoration are incomplete |
| Empty states | 8/10 | Honest, specific, and do not invent data | Where the user has permission, provide one direct next action consistently |
| Loading states | 3/10 | Individual submit buttons often show progress | No route-level loading UI; some server-form actions lack a visible local pending state |
| Error states | 4/10 | Server actions use safe Arabic messages | No route error boundary/retry surface |
| Success states | 7/10 | Inline `aria-live` feedback is common | Feedback can remain inside a long form or card and be missed after submission |
| Responsive behavior | 7/10 | No horizontal overflow was observed on the current 390px sign-in check | First-task placement and mobile menu behavior need correction |
| RTL support | 8/10 | Root direction, Arabic font, and LTR islands are intentionally implemented | Continue checking mixed identifiers, arrows, date inputs, and status sequences in real browsers |
| Dark mode | 2/10 | Not currently implemented and not required for the current release | Do not build it without user demand; improve light-mode contrast first |

## Page-by-page audit

Scores below combine source evidence with current browser evidence where available. Protected pages were not authenticated in this audit; their runtime score is therefore based on checkout components and existing local screenshots, not a claim about a managed deployment.

| Route | Score | Strengths | Main weakness | Best next enhancement | Priority / effort |
|---|---:|---|---|---|---|
| `/` | 8/10 | Safely redirects to sign-in | No issue validated | Keep as-is | Low / none |
| `/sign-in` | 6/10 | Distinctive desktop identity; clear security framing | Login is below the fold on mobile; two full methods lengthen the page | Compact mobile brand header and progressive disclosure for magic link | High / low |
| `/security/mfa` | 7/10 | Clear gated flow, QR fallback, OTP semantics | `AAL2` is internal language; no obvious cancel/sign-out path | Use plain language and provide an explicit safe exit/recovery action | High / low |
| `/access-pending` | 7/10 | Safe, calm explanation without leaking organization data | Recovery depends on an unspecified administrator | Name the next human action and provide sign-out/account-switch where supported | Medium / low |
| `not-found` | 8/10 | Arabic, safe, concise, no path echo | Only one destination | Keep as-is unless support evidence shows another common recovery route | Low / none |
| `/workspace` | 7/10 | Clear status, recent leads, approvals, role-aware shell | Totals are less actionable than the page promise; brass CTA contrast fails | Fix contrast now; validate an attention-first rail later | High now / medium later |
| `/workspace/leads` | 6/10 | Simple data model and honest creation boundary | Creation form precedes the queue; no findability at volume | Collapse creation form; add search/status only at threshold | High / medium |
| `/workspace/clients` | 6/10 | Clear registry and straightforward create action | Card-only registry will become sparse and slow to scan | List-first layout; threshold-triggered search | Medium / medium |
| `/workspace/properties` | 7/10 | Strong property identity, status and mixed-direction handling | Large header + full form + card grid creates substantial empty space | Compact header and expandable create form | High / medium |
| `/workspace/property-owners` | 7/10 | Clear business-record distinction and useful contact presentation | Same form-first/card-density issue; likely needs faster lookup | Expandable create form; search only when records justify it | Medium / medium |
| `/workspace/availability` | 7/10 | Date-range rule and occupancy boundary are clearly communicated | Cards do not provide a calendar or property-focused scan | Keep list now; add property/date filter before considering a calendar | Medium / low |
| `/workspace/bookings` | 7/10 | Lifecycle actions and statuses are visible; half-open date rule is explained | Approval/confirm/check-in actions compete inside cards; no queue filtering | Emphasize one valid next action per booking; filter by status/date at threshold | High / medium |
| `/workspace/tasks` | 6/10 | Clear types, status labels, due times, and forward workflow | Form dominates; 40px action buttons and card-only queue | List-first view, 44px actions, today/status filters when needed | High / medium |
| `/workspace/transport` | 6/10 | Rich operational coverage and honest finance/provider boundaries | Too many forms and inventories on one long page; destructive cancel is immediate | Default to request queue; reveal fleet/setup forms; confirm cancellation | High / medium |
| `/workspace/approvals` | 6/10 | Maker-checker boundary is visible; status is not color-only | Two decision forms repeat per request and require too much vertical space | Show details once, then reveal approve/reject reason after choosing an action | High / medium |
| `/workspace/activity` | 6/10 | Concise audit outcomes and safe identifiers | Raw fallback action/resource names may expose technical vocabulary; no filter | Localize all known events; add date/outcome filter only at volume | Medium / low |
| `/workspace/notifications` | 6/10 | Read/unread state and timestamps are clear | Small “read” target, no bulk handling, long pages at volume | Make row action 44px; add “mark visible as read” only after demonstrated need | High / low |
| `/workspace/whatsapp` | 6/10 | Human-control boundaries and empty states are unusually honest | Provider configuration and implementation terms are mixed into operator UI | Separate admin setup from inbox; rewrite all copy in staff language | High / medium |
| `/workspace/ai` | 6/10 | Proposal-only boundary and tool decisions are explicit | The screen reads like an engineering console, not an operator assistant | Lead with available tasks and results; move model/tool metadata to expandable details | High / medium |

## UX review

### Navigation and discoverability

The desktop navigation is clear and role-filtered, but it exposes up to 14 destinations in two groups. This is acceptable for the present modular monolith; do not add nested navigation yet. Improve the current model by making mobile active state and focus behavior match desktop. If user research later shows destination confusion, reorganize by the actual workflow—demand, stays, operations, governance—without changing routes.

### Cognitive load and efficiency

The repeated pattern “large page hero → full creation form → cards” makes each screen understandable in isolation but slows experienced operators. The best lean change is list-first progressive disclosure: retain the existing form and server action, but hide it until the user chooses “إضافة”. This is smaller and safer than introducing drawers, modal infrastructure, or a new form framework.

### Feedback and errors

Inline feedback is the right default because it keeps the result next to the command. It should be focused or scrolled into view when a submission completes, and every state-changing control should expose a pending state. A global toast system is not required. Add a route-level Arabic error/retry surface for failed reads.

### Content design

Write from the operator’s side of the screen. Technical assurances belong in documentation or expandable details unless they change the user’s decision. Preserve important boundaries—“لن يتم الإرسال الآن”, “لا ينشئ دفعة”, “تحتاج موافقة”—but remove names of internal implementation mechanisms.

### Dashboard

The page should answer: “What must I do next?” Existing totals are useful context, but they should not displace pending approvals, overdue tasks, arrivals, or unresolved conversations. Do not add charts. Validate the top three daily decisions with actual operators first; then introduce one time-ordered attention rail using existing data.

## Accessibility review

Target **WCAG 2.2 AA** for the next frontend pass.

1. Increase normal small text and strengthen muted colors. A bold 10–11px label is still difficult to read even when its theoretical ratio passes.
2. Replace the brass CTA background or its foreground combination. `#85652e` with white measures about 5.39:1 and preserves the current palette better than `#b88a3a` with white.
3. Use a focus indicator that reaches at least 3:1 against adjacent light surfaces; pale sea-glass alone is not enough.
4. Make all actionable controls at least 44×44 CSS pixels. The current source includes multiple 36px and 40px targets.
5. Treat mobile navigation as a real modal disclosure: focus entry, focus containment, focus return, backdrop, Escape, and active route.
6. Keep status text/icons in addition to color. This is already done well on most workflow cards.
7. Ensure success/error announcements use appropriate live-region behavior and move focus only when the response would otherwise be missed.
8. Add a “skip to content” link before the persistent workspace navigation.
9. Verify table headers, mixed-direction dates/IDs, native date controls, 200% zoom, and screen-reader order in authenticated browser tests.

## Design-system review

### Preserve

- `canvas`, `surface`, `harbor`, `tide`, `sea-glass`, `sand`, `coral`, and `line` as the recognizable Voya palette.
- Noto Kufi Arabic for interface copy and Geist Mono for canonical identifiers/dates.
- Quiet motion, rounded but restrained surfaces, pine navigation, and sage operational states.

### Tighten

- Add one accessible muted-text token and one accessible brass-action token instead of repeating nearby hex values.
- Define a minimum utility type size and a 44px control-size rule.
- Standardize a compact operational page header, an empty state, a status pill, and inline command feedback.
- Reduce large-radius nested cards. Use separators and row rhythm when the content is a queue rather than an independent object gallery.
- Extract shared components only while fixing repeated screens; do not start a separate design-system program.

### Signature element

Voya’s memorable element should be an **operations rail ordered by stay time**, not another generic KPI grid. Use it only on the dashboard, after workflow validation, and keep the rest of the product quiet. This connects the design directly to furnished-rental work without adding decoration.

## Mobile, responsive, and motion review

### Mobile

- Fix sign-in order first; it is the only current browser-verified first-screen blocker.
- Keep forms single-column and full-width; current inputs already do this well.
- Prefer compact headers and collapsed creation forms so the queue appears sooner.
- Avoid horizontal tables except for genuinely comparative data; use row cards on mobile and denser rows/tables on desktop.

### Responsive

- Current sign-in did not show horizontal overflow at 390px.
- Existing grids generally collapse safely, but content priority—not overflow—is the main problem.
- Test 320px, 390px, 768px, 1280px, and 200% zoom for every changed flow.

### Motion

Motion is appropriately restrained, and the global reduced-motion rule is a strength. Keep only state transitions, progress indicators, and subtle focus/hover feedback. No page transition or animation framework is justified.

## Frontend architecture notes

- Thin App Router pages and feature-owned UI are a sound fit for the current modular monolith.
- The full-page client components are acceptable at the current scale. Splitting every card into server/client islands would be premature optimization.
- Repeated long JSX and hard-coded style values make cross-product accessibility fixes harder. Consolidate only the patterns touched by the roadmap.
- Missing route loading/error boundaries are a user-experience gap, not a reason to introduce a new state-management library.
- Do not add client-side authorization state. Navigation visibility and action affordances must continue to reflect server-derived membership while database/RPC checks remain authoritative.

## Security review of the recommendations

The recommendations do not require relaxing any current security invariant.

- Search, filtering, and pagination must remain organization-scoped on the server; never accept a client organization or role as authority.
- UI hiding must never replace RPC authorization.
- Error screens and action feedback must not expose provider responses, SQL details, internal request payloads, membership IDs, or secrets.
- Confirmation UI must not bypass maker-checker, occupancy, idempotency, or state-machine checks.
- Mobile navigation and progressive form disclosure are presentation changes only; server-rendered role filtering remains the source of visible destinations.
- Do not persist sensitive drafts, guest data, phone numbers, or AI prompts in browser storage merely to improve perceived convenience.

## Verification required for any later implementation

- Unit tests for new copy/state behavior and component variants.
- Integration tests for loading, retry, denied, invalid, success, and idempotent resubmission paths.
- Authenticated browser tests for every affected role, desktop/mobile navigation, keyboard focus, RTL, 200% zoom, and protected-route rendering.
- Automated accessibility checks plus manual keyboard and screen-reader smoke checks.
- Contrast verification for every token pair and state, including focus, disabled, hover, and placeholder states.
- Lint, full tests, production render checks, and the project security scan before a commit.

## Explicitly not recommended now

- No full visual redesign.
- No dark mode.
- No command palette.
- No drag-and-drop boards.
- No dashboard chart suite.
- No animation framework.
- No new UI component dependency or standalone design-system project.
- No guest portal, marketplace, finance UI, autonomous AI actions, or outbound WhatsApp expansion.
- No search/filter framework until actual list volume or operator evidence triggers it.

## Final recommendation

Treat the current Design C identity as approved direction and run one lean frontend quality pass around **mobile first-task visibility, WCAG contrast/type/targets, mobile navigation, plain Arabic operator copy, and list-first page hierarchy**. These changes provide the highest usability return without changing architecture or product scope.
