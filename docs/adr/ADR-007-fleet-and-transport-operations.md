# ADR-007: Fleet and transport operations foundation

## Status

Accepted — 2026-08-01

## Context

The approved operational workflow includes cars, drivers, car rentals, and airport transfers. The product must record these facts per organization without pretending that pricing, payment, provider delivery, or driver compensation policy exists.

## Decision

Add tenant-scoped `fleet_vehicles`, `fleet_drivers`, and `transport_requests` tables behind security-definer RPCs. Every command derives the actor from `auth.uid()`, checks active membership and role, writes audit/outbox evidence in the same transaction, and keeps browser roles away from direct table access. The Design C route exposes resource setup, request creation, assignment, and human-controlled status changes.

Transport requests intentionally store operational locations, times, passengers, optional booking linkage, and notes only. They do not calculate or store a price, collect payment, call a provider, or claim that a ride was delivered.

## Consequences

The team can coordinate real internal transfers and rentals now, while finance/provider policy remains an explicit launch decision. A later provider adapter must consume outbox events through a reviewed worker and preserve the same request/status/audit boundary.

## Verification

`supabase/tests/transport_operations.sql`, the transport feature unit tests, authenticated route coverage, lint, build, and the guarded disposable database suite.
