# Security review: fleet and transport operations

## Scope

Reviewed migration `20260801000500_transport_operations.sql`, the transport server actions/page, and Design C UI.

## Findings

- Tenant isolation is enforced by composite foreign keys and every RPC membership predicate.
- Browser roles receive no direct table privileges; only authenticated RPC execution is granted.
- Fleet creation and assignment are restricted to owner, manager, and operations. Sales can create and read its own transport requests, but cannot manage the fleet.
- Assignment rejects inactive resources and terminal request states. Status changes are audited and do not mutate bookings or financial records.
- Idempotent transport creation returns the original request only when the normalized payload matches; conflicting reuse fails.
- Audit/outbox payloads contain identifiers and operational metadata only; no provider secret or payment credential is stored.

## Residual risks

Provider webhooks, external delivery, pricing, payment, and driver compensation are not implemented and must remain disabled until their contracts and retention policies are approved. A future worker must reauthorize the organization and request state before consuming any transport event.

## Evidence

The guarded SQL suite asserts direct-grant denial, idempotent creation, assignment/status evidence, outbox creation, and suspended-member denial.
