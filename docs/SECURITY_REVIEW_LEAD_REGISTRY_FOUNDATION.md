# Security Review: Lead Registry Foundation

## Approved scope

The `leads` registry is tenant-scoped and command-owned. It stores only title, controlled source/status, optional requested date range, and an optional same-tenant active assignee. It stores no contact PII, consent, notes, budget, quote, booking, or finance data.

## Controls

- Browser roles receive no direct table read/write grant; only security-definer RPCs are executable.
- The database derives actor membership from `auth.uid()`, enforces organization-scoped active roles, tenant-qualified assignment, date validity, and tenant idempotency.
- Each successful creation commits `lead.created` audit and outbox evidence together with the record.
- Read results are tenant-filtered; sales agents are restricted to unassigned or self-assigned leads.
- UI/server action never accepts organization or actor identity from the form, and returns generic Arabic failures.

## Residual risks and blockers

- PII, consent, lead notes, duplicate detection/merge, conversion/linking, assignment/status updates, exports, and retention policy require distinct approval, field policy, migrations, tests, and audit review.
- The migration has passed an ephemeral local PostgreSQL suite only; it has not been pushed to Supabase or deployed.
