# Security review: operations task registry

## Scope

Reviewed `20260801000400_operations_tasks.sql`, the `/workspace/tasks` route/actions, and the Design C task UI.

## Controls verified

- Direct `authenticated` table reads/updates are revoked; all operations use allowlisted RPCs.
- Organization, booking, assignee, and actor relationships are validated inside SECURITY DEFINER functions.
- Owner/manager/operations roles are required for task reads and writes; suspended viewers are denied.
- Idempotent creation, status changes, audit events, and outbox evidence are covered by `supabase/tests/operations_tasks.sql`.
- Task completion does not mutate booking, financial, or approval source records.

## Residual work

Assignment queues, notification delivery, escalation/SLA policy, and automatic task generation from booking transitions require separate product decisions and provider/worker tests.
