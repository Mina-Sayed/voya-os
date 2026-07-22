# Security review: audit activity workspace

- The immutable `audit_events` table is still inaccessible directly to browser roles.
- `list_audit_activity` has a fixed search path, bounded limit, active-membership authorization, and returns only ID, action, resource kind/ID, outcome, and timestamp.
- owner/manager receive tenant-scoped activity; sales and operations receive only their own actor-linked activity; accountant receives finance-prefix activity only; viewer and suspended memberships are denied.
- The UI never receives `before_delta`, `after_delta`, request IDs, reason codes, actor identifiers, or approval snapshots.
- The activity view is read-only and cannot alter, export, or replay audit facts.
