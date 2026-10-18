-- Voya OS: make outbox delivery capability an explicit, database-owned registry.
--
-- Migrations enqueue many event types (CRM, property, property_owner,
-- property.image, fleet, transport, booking.*, availability_block,
-- operations.task, ...) that the delivery worker's inline IN (...) allow-list
-- never matched. Those rows could never leave state = 'pending' with
-- attempts = 0, and purge_outbox_events only removed completed/dead_letter, so
-- they accumulated forever.
--
-- The fix is NOT to widen that IN (...) list: the Edge worker branches on
-- event_type with no catch-all, so claiming an unroutable type would hand the
-- worker events it cannot handle. Instead the registry below is the single
-- source of truth for "can the delivery worker route this type at all":
--
--   * deliverable = true  -> exactly the event types supabase/functions/
--     outbox-dispatch can route. These keep the default 'pending' state.
--   * deliverable = false -> recorded as durable, retention-eligible facts
--     that no delivery worker will ever lease.
--
-- Reads of the registry happen only inside SECURITY DEFINER functions, so the
-- table carries no direct grants for any role.

-- ---------------------------------------------------------------------------
-- 1. Capability registry
-- ---------------------------------------------------------------------------

CREATE TABLE public.outbox_event_delivery_capability (
  event_type text PRIMARY KEY
    CHECK (event_type ~ '^[a-z][a-z0-9_]*([.][a-z][a-z0-9_]*)+$'),
  deliverable boolean NOT NULL DEFAULT false,
  note text CHECK (note IS NULL OR char_length(btrim(note)) BETWEEN 1 AND 400),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

ALTER TABLE public.outbox_event_delivery_capability ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.outbox_event_delivery_capability FORCE ROW LEVEL SECURITY;

-- No role receives direct access: anon/authenticated cannot read the routing
-- registry from a browser, and neither does the worker role. Only the
-- SECURITY DEFINER claim function below reads it.
REVOKE ALL ON TABLE public.outbox_event_delivery_capability FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.outbox_event_delivery_capability FROM voya_outbox_worker, service_role;

COMMENT ON TABLE public.outbox_event_delivery_capability IS
  'Single source of truth for outbox delivery routability. deliverable = true is restricted to event types the Edge dispatch worker can route; every other registered type is recorded as a durable non-delivery fact.';
COMMENT ON COLUMN public.outbox_event_delivery_capability.deliverable IS
  'True only for event types claim_outbox_delivery_events may lease. Registered-but-false and unregistered types are both non-deliverable (fail closed).';

-- ---------------------------------------------------------------------------
-- 2. Seed every event_type any migration in this checkout can produce
-- ---------------------------------------------------------------------------
--
-- Enumerated from `INSERT INTO public.outbox_events` across
-- supabase/migrations/*.sql, including the types assembled by concatenation:
--   'booking.approval.' || p_decision  (p_decision IN approved, rejected)
--   'booking.' || p_event_type         (p_event_type IN check_in, check_out)

INSERT INTO public.outbox_event_delivery_capability (event_type, deliverable, note) VALUES
  -- Routed by supabase/functions/outbox-dispatch. Keep in sync with the
  -- worker's event_type branches; tests/outbox_delivery_capability.sql fails
  -- if this set drifts.
  ('organization.invitation.send_requested', true, 'Invitation email handed to the dispatch worker'),
  ('member.invitation.resent', true, 'Invitation resend email handed to the dispatch worker'),
  ('whatsapp.message.send_requested', true, 'Outbound WhatsApp delivery handed to the dispatch worker'),
  ('whatsapp.ai.respond_requested', true, 'AI WhatsApp reply handed to the dispatch worker'),
  ('whatsapp.media.store_requested', true, 'Accepted media storage handed to the dispatch worker'),
  ('ai.run.requested', true, 'AI agent run handed to the dispatch worker'),
  ('ai.data_entry.requested', true, 'AI data-entry run handed to the dispatch worker'),

  -- Domain facts with no delivery route. Recorded, never leased.
  ('availability_block.created', false, 'Availability block domain fact'),
  ('ai.data_entry.input.mapped', false, 'AI data-entry mapping domain fact'),
  ('ai.data_entry.submitted', false, 'AI data-entry submission domain fact'),
  ('booking.amended', false, 'Booking amendment domain fact'),
  ('booking.amendment.requested', false, 'Booking amendment request domain fact'),
  ('booking.approval.approved', false, 'Approval decision domain fact'),
  ('booking.approval.rejected', false, 'Approval decision domain fact'),
  ('booking.approval.requested', false, 'Approval request domain fact'),
  ('booking.cancellation.requested', false, 'Cancellation request domain fact'),
  ('booking.cancelled', false, 'Cancellation outcome domain fact'),
  ('booking.check_in', false, 'Booking stay event domain fact'),
  ('booking.check_out', false, 'Booking stay event domain fact'),
  ('booking.commercial_approval.requested', false, 'Commercial approval request domain fact'),
  ('booking.commercial_confirmed', false, 'Commercial booking confirmation domain fact'),
  ('booking.commercial_draft.created', false, 'Commercial booking draft domain fact'),
  ('booking.confirmed', false, 'Booking confirmation domain fact'),
  ('client.created', false, 'Client registry domain fact'),
  ('fleet.driver.created', false, 'Fleet driver domain fact'),
  ('fleet.vehicle.created', false, 'Fleet vehicle domain fact'),
  ('lead.archived', false, 'Lead lifecycle domain fact'),
  ('lead.converted', false, 'Lead lifecycle domain fact'),
  ('lead.created', false, 'Lead lifecycle domain fact'),
  ('lead.follow_up.completed', false, 'Lead follow-up domain fact'),
  ('lead.follow_up.created', false, 'Lead follow-up domain fact'),
  ('lead.updated', false, 'Lead lifecycle domain fact'),
  ('operations.task.created', false, 'Operations task domain fact'),
  ('property.archived', false, 'Property lifecycle domain fact'),
  ('property.created', false, 'Property lifecycle domain fact'),
  ('property.image.archived', false, 'Property image domain fact'),
  ('property.image.registered', false, 'Property image domain fact'),
  ('property.restored', false, 'Property lifecycle domain fact'),
  ('property.updated', false, 'Property lifecycle domain fact'),
  ('property_owner.archived', false, 'Property owner domain fact'),
  ('property_owner.assignment_created', false, 'Property owner domain fact'),
  ('property_owner.created', false, 'Property owner domain fact'),
  ('property_owner.restored', false, 'Property owner domain fact'),
  ('property_owner.updated', false, 'Property owner domain fact'),
  ('transport.request.assigned', false, 'Transport assignment domain fact'),
  ('transport.request.created', false, 'Transport request domain fact'),
  ('whatsapp.message.queued', false, 'Outbound message queueing domain fact')
ON CONFLICT (event_type) DO UPDATE
SET deliverable = EXCLUDED.deliverable,
    note = EXCLUDED.note;

-- ---------------------------------------------------------------------------
-- 3. 'recorded' is a first-class terminal-for-delivery state
-- ---------------------------------------------------------------------------
--
-- Same DROP IF EXISTS + ADD CONSTRAINT shape as the 'needs_review' extension
-- in 20260813013307_outbox_dispatch_v1.sql. The new constraint is added NOT
-- VALID and validated separately so the rewrite does not hold an ACCESS
-- EXCLUSIVE lock while re-scanning a growing table.

ALTER TABLE public.outbox_events
  DROP CONSTRAINT IF EXISTS outbox_events_state_check;

ALTER TABLE public.outbox_events
  ADD CONSTRAINT outbox_events_state_check
  CHECK (state IN ('pending', 'processing', 'retry_wait', 'recorded', 'completed', 'dead_letter', 'needs_review'))
  NOT VALID;

ALTER TABLE public.outbox_events VALIDATE CONSTRAINT outbox_events_state_check;

COMMENT ON COLUMN public.outbox_events.state IS
  'pending, processing, retry_wait, recorded, completed, dead_letter, or needs_review. recorded means the event type has no delivery route; see public.outbox_event_delivery_capability.';

-- ---------------------------------------------------------------------------
-- 4. Insert-time routing decision
-- ---------------------------------------------------------------------------
--
-- Scope note, read this before changing the predicate below. The registry
-- above seeds every event_type any migration in this checkout can produce, so
-- "registered and deliverable = false" covers the whole real backlog. An
-- event_type with NO registry row is not downgraded at insert time: the legacy
-- generic lifecycle contract public.claim_outbox_events still owns pending
-- rows of types it was written for (supabase/tests/outbox_foundation.sql
-- exercises it with a test-only 'notification.prepare' type this migration
-- does not own the vocabulary of). Unregistered types are still fail closed
-- where it matters: claim_outbox_delivery_events joins this registry, so they
-- can never be leased. The parity assertions in
-- supabase/tests/outbox_delivery_capability.sql pin the registry to the full
-- migration-produced vocabulary, so a new unregistered production type fails
-- the suite instead of accumulating silently.

CREATE OR REPLACE FUNCTION public.apply_outbox_event_delivery_capability_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  -- Only the default delivery backlog is re-routed here. An explicit
  -- 'processing'/'needs_review'/'dead_letter' insert is a deliberate lifecycle
  -- decision (recovery, quarantine and regression fixtures), so it is never
  -- rewritten. Rewriting it would also break outbox_event_lease_consistency:
  -- 'recorded' is not 'processing', so locked_by/locked_until must stay NULL.
  IF NEW.state = 'pending' AND EXISTS (
    SELECT 1
    FROM public.outbox_event_delivery_capability AS capability
    WHERE capability.event_type = NEW.event_type
      AND NOT capability.deliverable
  ) THEN
    NEW.state := 'recorded';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_outbox_event_delivery_capability_v1() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER outbox_events_apply_delivery_capability
  BEFORE INSERT ON public.outbox_events
  FOR EACH ROW
  EXECUTE FUNCTION public.apply_outbox_event_delivery_capability_v1();

-- ---------------------------------------------------------------------------
-- 5. Claim strictly from the registry
-- ---------------------------------------------------------------------------
--
-- The inline allow-list is gone. An event type that is not registered
-- deliverable cannot be claimed, so the claim boundary stays closed even if a
-- future migration forgets to register its event types. Eligibility,
-- ordering, locking, lease write-back and the attempt increment are unchanged.

CREATE OR REPLACE FUNCTION public.claim_outbox_delivery_events(
  p_worker_id text,
  p_limit integer,
  p_lease_seconds integer
)
RETURNS SETOF public.outbox_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120
    OR p_limit IS NULL OR p_limit < 1 OR p_limit > 20
    OR p_lease_seconds IS NULL OR p_lease_seconds < 1 OR p_lease_seconds > 900 THEN
    RAISE EXCEPTION 'outbox claim input is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.outbox_events AS event
  SET state = 'needs_review',
      locked_by = NULL,
      locked_until = NULL,
      last_error_code = 'worker_lease_expired_ambiguous'
  WHERE event.event_type = 'whatsapp.message.send_requested'
    AND event.state = 'processing'
    AND event.locked_until <= timezone('utc', now());

  RETURN QUERY
  WITH eligible AS (
    SELECT event.id
    FROM public.outbox_events AS event
    JOIN public.outbox_event_delivery_capability AS capability
      ON capability.event_type = event.event_type
     AND capability.deliverable
    WHERE (
        (event.state IN ('pending', 'retry_wait') AND event.available_at <= timezone('utc', now()))
        OR (event.state = 'processing' AND event.locked_until <= timezone('utc', now()))
      )
    ORDER BY CASE WHEN event.state = 'processing' THEN event.locked_until ELSE event.available_at END ASC,
             event.created_at ASC
    LIMIT p_limit
    FOR UPDATE OF event SKIP LOCKED
  )
  UPDATE public.outbox_events AS event
  SET state = 'processing',
      attempts = event.attempts + 1,
      locked_by = p_worker_id,
      locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds),
      last_error_code = NULL
  FROM eligible
  WHERE event.id = eligible.id
  RETURNING event.*;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_outbox_delivery_events(text, integer, integer) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.claim_outbox_delivery_events(text, integer, integer) TO voya_outbox_worker, service_role;

COMMENT ON FUNCTION public.claim_outbox_delivery_events(text, integer, integer) IS
  'Leases deliverable outbox events. public.outbox_event_delivery_capability is the single source of truth: an event type with no registry row, or a row with deliverable = false, is never returned.';

-- ---------------------------------------------------------------------------
-- 6. Retention covers recorded rows
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.purge_outbox_events(
  p_retention_seconds integer,
  p_limit integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  deleted_count integer;
BEGIN
  IF p_retention_seconds IS NULL OR p_retention_seconds < 3600 OR p_retention_seconds > 31536000 THEN
    RAISE EXCEPTION 'retention must be between 3600 and 31536000 seconds' USING ERRCODE = '22023';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
    RAISE EXCEPTION 'purge limit must be between 1 and 1000' USING ERRCODE = '22023';
  END IF;

  WITH eligible AS (
    SELECT id
    FROM public.outbox_events
    WHERE state IN ('recorded', 'completed', 'dead_letter')
      AND updated_at <= timezone('utc', now()) - make_interval(secs => p_retention_seconds)
    ORDER BY updated_at ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.outbox_events AS event
  USING eligible
  WHERE event.id = eligible.id;

  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

REVOKE ALL ON FUNCTION public.purge_outbox_events(integer, integer) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.purge_outbox_events(integer, integer) TO voya_outbox_worker, service_role;

-- ---------------------------------------------------------------------------
-- 7. Idempotent backfill of rows stranded before this migration
-- ---------------------------------------------------------------------------
--
-- Rows written before the trigger existed sat at state = 'pending',
-- attempts = 0 with no route. Re-running this is a no-op.
--
-- Deliberately stricter than the insert trigger: this is a one-time repair of
-- rows that predate the registry, so an unregistered type in history is by
-- construction not deliverable and is recorded.

UPDATE public.outbox_events AS event
SET state = 'recorded'
WHERE event.state = 'pending'
  AND event.attempts = 0
  AND NOT EXISTS (
    SELECT 1
    FROM public.outbox_event_delivery_capability AS capability
    WHERE capability.event_type = event.event_type
      AND capability.deliverable
  );