# Voya OS Design C — UI/UX System

Status: Implemented live workspace slice
Scope: Arabic RTL operational workspace

## Direction

Voya is a hospitality operations command center, not a marketing dashboard. The interface uses a calm ivory canvas, a deep pine navigation rail, sage operational surfaces, and a restrained brass action color. Data stays dense enough for daily work without turning every state into a card grid.

## Tokens

| Token | Value | Use |
|---|---|---|
| `canvas` | `#f3efe6` | outer application canvas |
| `surface` | `#fbfaf7` | page and panel surfaces |
| `harbor` | `#153b34` | navigation, primary text, primary actions |
| `tide` | `#1a6958` | success, links, active operational state |
| `sea-glass` | `#d5e9df` | selected navigation and quiet emphasis |
| `sand` | `#e4d3ae` | brass action/supporting status |
| `coral` | `#b85f4c` | blocked, attention, failure |
| `line` | `#d9dfd8` | borders and separators |

Typography remains Noto Kufi Arabic for Arabic UI and Geist Mono for canonical dates/identifiers. Headings use tight tracking and sentence case; labels are short and action-oriented.

## Shell rules

- Every protected route uses `WorkspaceShell` with one persistent navigation model.
- Organization and role are server-derived and shown as context, never editable browser state.
- A not-yet-enabled provider or policy renders an honest state inside an actionable workflow; never use fake data or fake delivery claims.
- Mobile keeps the same destinations through the existing menu and touch-sized controls.
- All pages retain loading, empty, error, and permission-denied states at their data boundary.

## Dashboard rules

`/workspace` is tenant-scoped and reads only allowlisted RPCs allowed for the active role. It must never render the old fixture dashboard. Missing role-permitted data is an empty state; an unauthorized RPC is not converted into guessed data.

## Accessibility

Use semantic headings, `aria-current` on the active route, visible focus rings, minimum touch targets around 44px, RTL-safe `dir="ltr"` for identifiers/dates, and no color-only status meaning.

## Current release boundary

The live Design C slice covers the workspace shell, dashboard, leads, clients, properties, owners, availability, booking drafts, maker-checker booking approval, confirmation, check-in/check-out, operations tasks, cars/drivers/transport requests, approvals, activity, notifications, the provider-neutral staff WhatsApp inbox, and the governed Agent Center read model. CRM contact consent and queued human replies are tenant-scoped; external delivery and model execution are intentionally disabled until provider, consent, retention, and worker policy contracts are specified and tested. Finance and self-service SaaS remain non-actionable.
