# Glossary

**Last verified:** 2026-08-03  
Terms that confuse humans and agents.

| Term | Means here | Does **not** mean |
|---|---|---|
| **Organization** | Tenant root row; isolation boundary | A single physical building |
| **Membership** | User’s role+status inside one organization | Auth user account itself |
| **Owner (role)** | `organization_memberships.role = 'owner'` | Property owner party |
| **Property owner** | `property_owners` business record | App admin / org owner role |
| **Property** | One independently bookable furnished unit | Entire building complex (hierarchy open) |
| **Client** | Canonical guest/customer record in an org | OAuth/API client |
| **Lead** | Sales pipeline prospect before/without full client linkage | Marketing website lead form product |
| **Booking** | Stay request aggregate with status machine | Confirmed inventory only (drafts exist too) |
| **Confirmed booking** | `status = 'confirmed'`; competes for occupancy | Any row in `bookings` |
| **Stay range** | Half-open `[check_in, check_out)` dates | Closed interval including checkout night twice |
| **Availability block** | Manual closure (maintenance/owner use/etc.) | Soft calendar suggestion |
| **Occupancy ledger** | Internal `property_occupancies` conflict table | User-facing report |
| **Approval request** | Immutable proposal snapshot awaiting decision/execution | Slack thumbs-up |
| **Maker-checker** | Requester ≠ decider for booking approval | Any two-person workflow outside coded rules |
| **Outbox** | DB table of post-commit side effects to process | Email product inbox |
| **Workspace** | Authenticated multi-tenant staff app area `/workspace` | VS Code / agent worktree only |
| **Server Action** | Next.js `"use server"` command boundary | Public REST resource automatically |
| **RPC / command** | PostgreSQL SECURITY DEFINER function used as write API | Browser-invoked arbitrary SQL |
| **Service role** | Supabase key bypassing RLS | Staff user role name |
| **AAL2** | Authenticator assurance level 2 (MFA satisfied session) | Having a factor enrolled but session still AAL1 |
| **Publishable key** | Supabase anon/publishable client key | Service role |
| **Design C** | Accepted workspace shell visual/IA direction (ADR-004) | Random CSS theme name |
| **Voya C program** | Product program docs for self-service AI/WhatsApp (design) | Fully shipped autonomous WhatsApp bot |
| **Agent (product)** | In-app AI assistant kind (sales/booking/…) | Codex development subagent |
| **Codex agent** | `.codex/agents/*` engineering roles | End-user AI assistant |
| **Memory** | `docs/memory/*` durable agent context | Chat transcript |
| **SECURITY_REVIEW_*** | Point-in-time review evidence | Living source of truth |
| **ADR** | Architecture Decision Record under `docs/adr/` | Informal chat decision |

## Status vocabulary (bookings)

`draft`, `pending_approval`, `confirmed`, `cancelled`, `completed` — see DOMAIN_RULES for which transitions are implemented.
