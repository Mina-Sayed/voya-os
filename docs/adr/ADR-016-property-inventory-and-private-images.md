# ADR-016: V1 property inventory, owner lifecycle, and private images

**Status:** Accepted for the V1 checkout; managed rollout is not verified
**Date:** 2026-08-13

## Context

The original property and owner foundation could create and read minimal
records, but V1 needs an operational inventory: location and capacity data,
owner contacts, lifecycle changes, bounded ownership periods, and private
property images. Browser-facing table writes and public storage URLs would
make tenant isolation and auditability too easy to bypass.

## Decision

- Use the tenant-scoped V1 RPCs in `20260813000100_property_inventory_v1.sql`
  for property and owner commands and reads.
- Keep property and owner lifecycle state explicit (`active`, `inactive`,
  `archived`), require optimistic versions for edits/archive/restore, and bind
  retries to organization-scoped idempotency keys.
- Represent owner assignments as half-open date periods. The database
  exclusion constraint remains authoritative for overlap; only active owners
  can receive new assignments.
- Store image metadata in `public.property_images`, but store bytes in the
  private `property-images` bucket. The server-only service-role path uploads
  bytes, the authenticated tenant-scoped RPC registers metadata, and the
  signed redirect route issues a five-minute URL only after membership and
  tenant checks.
- Enforce JPEG/PNG/WebP, 10 MiB per file, 20 active images per property, MIME
  and extension agreement, tenant-qualified paths, and no public bucket.

## Consequences

This gives the V1 UI a complete local inventory contract without inventing
owner settlements, finance, or public media policy. Image upload and signed
URL behavior still require a separate managed Supabase Storage configuration
and staging verification; local SQL tests intentionally omit the provider
storage schema.

## Evidence

- Migration: `supabase/migrations/20260813000100_property_inventory_v1.sql`
- SQL proof: `supabase/tests/property_inventory_v1.sql`
- Server actions/UI: `src/app/workspace/properties/`,
  `src/app/workspace/property-owners/`, and `src/app/api/workspace/properties/`
