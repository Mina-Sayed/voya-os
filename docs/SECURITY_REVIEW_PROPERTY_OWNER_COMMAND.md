# Security Review: Property Owner Creation Command

Date: 2026-07-22

## Scope and boundary

`create_property_owner` is a server-owned database command for creating an
active property-owner business record. It is not a membership/role operation,
does not modify ownership periods, and cannot update or delete an owner.

## Controls verified

- `property_owners` remains unavailable for direct `authenticated` inserts.
- The `SECURITY DEFINER` function has a fixed `pg_catalog` search path and is
  granted only to `authenticated`.
- It derives the actor from `auth.uid()` and requires an active `owner`,
  `manager`, or `operations` membership in the requested organization.
- The required display name and idempotency key are validated in the function.
- A repeated identical request returns the original resource; differing reuse
  of an idempotency key fails.
- Creation and the `property_owner.created` audit event are atomic.

## Residual controls

Ownership periods, owner deactivation, documents, settlement visibility, and
ownership reassignment remain separate approved commands. They must not gain
access by extending this create function or granting base-table writes.
