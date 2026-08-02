# ADR-006: Tenant-scoped operations task registry

## Status

Accepted for the core operations preview.

## Context

The product workflow requires staff to carry work from a booking request through arrival, departure, cleaning, maintenance, support, and handoff. A booking record alone does not expose ownership or the next operational step.

## Decision

Add `operations_tasks` as an append-evidenced, tenant-scoped work queue. Tasks have a generic stable type, title, optional description/due time/booking reference, assignment, and explicit status. Creation is idempotent; status changes are server-side RPCs with membership authorization, audit evidence, and an outbox event for future notifications.

The browser cannot write the task table directly. The UI never changes a booking state as a side effect of task creation or completion.

## Consequences

Operations can coordinate real work without inventing pricing, payment, cancellation, or settlement policy. Future assignment, escalation, notification, and booking-transition workflows can build on the task identity and audit trail.
