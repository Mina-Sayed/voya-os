-- Voya OS: registry-driven outbox delivery capability.
--
-- Proves that public.outbox_event_delivery_capability, not an inline allow-list,
-- decides what the delivery worker may lease, and that undeliverable event types
-- become retention-eligible 'recorded' facts instead of stranded 'pending' rows.
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_organization_id uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_deliverable_id uuid;
  v_non_delivery_id uuid;
  v_unregistered_id uuid;
BEGIN
  IF to_regclass('public.outbox_event_delivery_capability') IS NULL THEN
    RAISE EXCEPTION 'outbox_event_delivery_capability registry is required';
  END IF;
  IF to_regprocedure('public.claim_outbox_delivery_events(text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'claim_outbox_delivery_events is required';
  END IF;

  -- (a) Every type the dispatch worker can route is registered deliverable.
  IF EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'organization.invitation.send_requested',
      'member.invitation.resent',
      'whatsapp.message.send_requested',
      'whatsapp.ai.respond_requested',
      'whatsapp.media.store_requested',
      'ai.run.requested',
      'ai.data_entry.requested'
    ]) AS required(event_type)
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.outbox_event_delivery_capability AS capability
      WHERE capability.event_type = required.event_type
        AND capability.deliverable
    )
  ) THEN
    RAISE EXCEPTION 'all seven delivery types must be registered deliverable';
  END IF;

  -- (b) Representative domain-fact types are registered but not deliverable.
  IF EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'availability_block.created',
      'availability_block.updated',
      'availability_block.deleted',
      'client.created',
      'lead.created',
      'operations.task.created',
      'property.created',
      'property.image.registered',
      'property_owner.created',
      'fleet.vehicle.created',
      'transport.request.created',
      'booking.confirmed',
      'booking.approval.requested',
      'booking.check_in',
      'booking.approval.approved',
      'whatsapp.message.queued'
    ]) AS unsupported(event_type)
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.outbox_event_delivery_capability AS capability
      WHERE capability.event_type = unsupported.event_type
        AND NOT capability.deliverable
    )
  ) THEN
    RAISE EXCEPTION 'representative non-delivery types must be registered deliverable = false';
  END IF;

  -- Parity guard: the deliverable set is exactly the seven known delivery
  -- types. Widening it would hand the Edge worker event types it cannot route.
  IF (
    SELECT count(*) FROM public.outbox_event_delivery_capability WHERE deliverable
  ) <> 7
    OR EXISTS (
      SELECT 1
      FROM public.outbox_event_delivery_capability AS capability
      WHERE capability.deliverable
        AND capability.event_type NOT IN (
          'organization.invitation.send_requested',
          'member.invitation.resent',
          'whatsapp.message.send_requested',
          'whatsapp.ai.respond_requested',
          'whatsapp.media.store_requested',
          'ai.run.requested',
          'ai.data_entry.requested'
        )
    ) THEN
    RAISE EXCEPTION 'the deliverable registry set must equal the seven known delivery types';
  END IF;

  -- (c) A deliverable insert stays in the default backlog and is claimable.
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload,
    available_at, created_at
  ) VALUES (
    v_organization_id, 'ai.run.requested', 1, 'capability-deliverable-claim', '{}'::jsonb,
    timezone('utc', now()) - interval '2 hours', timezone('utc', now()) - interval '2 hours'
  ) RETURNING id INTO v_deliverable_id;

  IF (SELECT state FROM public.outbox_events WHERE id = v_deliverable_id) <> 'pending'
     OR (SELECT attempts FROM public.outbox_events WHERE id = v_deliverable_id) <> 0 THEN
    RAISE EXCEPTION 'a registered deliverable event must keep the default pending backlog';
  END IF;

  -- (d) A non-delivery insert is recorded, never leased.
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload,
    available_at, created_at
  ) VALUES (
    v_organization_id, 'property.created', 1, 'capability-non-delivery-record', '{}'::jsonb,
    timezone('utc', now()) - interval '2 hours', timezone('utc', now()) - interval '2 hours'
  ) RETURNING id INTO v_non_delivery_id;

  IF (SELECT state FROM public.outbox_events WHERE id = v_non_delivery_id) <> 'recorded' THEN
    RAISE EXCEPTION 'a registered non-deliverable event must be recorded, not left pending';
  END IF;

  -- (f) The recorded row keeps outbox_event_lease_consistency: no lease columns.
  IF (SELECT locked_by FROM public.outbox_events WHERE id = v_non_delivery_id) IS NOT NULL
     OR (SELECT locked_until FROM public.outbox_events WHERE id = v_non_delivery_id) IS NOT NULL THEN
    RAISE EXCEPTION 'a recorded outbox event must not carry a lease';
  END IF;

  -- (e) An unregistered type is fail closed at the claim boundary.
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload,
    available_at, created_at
  ) VALUES (
    v_organization_id, 'capability.unregistered.probe', 1, 'capability-unregistered-probe', '{}'::jsonb,
    timezone('utc', now()) - interval '2 hours', timezone('utc', now()) - interval '2 hours'
  ) RETURNING id INTO v_unregistered_id;

  IF EXISTS (SELECT 1 FROM public.outbox_event_delivery_capability WHERE event_type = 'capability.unregistered.probe') THEN
    RAISE EXCEPTION 'the fail-closed probe type must not be present in the registry';
  END IF;

  -- One claim pass proves the delivery boundary: the deliverable row is leased,
  -- the recorded row and the unregistered row never are.
  IF NOT EXISTS (
    SELECT 1 FROM public.claim_outbox_delivery_events('capability-claim-worker', 20, 300)
    WHERE id = v_deliverable_id
  ) THEN
    RAISE EXCEPTION 'the delivery worker must claim registered deliverable events';
  END IF;
  IF (SELECT state FROM public.outbox_events WHERE id = v_deliverable_id) <> 'processing'
     OR (SELECT attempts FROM public.outbox_events WHERE id = v_deliverable_id) <> 1 THEN
    RAISE EXCEPTION 'a claimed deliverable event must be leased and its attempt counted';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.claim_outbox_delivery_events('capability-claim-worker-2', 20, 300)
    WHERE id IN (v_non_delivery_id, v_unregistered_id)
  ) THEN
    RAISE EXCEPTION 'the delivery worker must never claim a recorded or unregistered event';
  END IF;
  IF (SELECT state FROM public.outbox_events WHERE id = v_non_delivery_id) <> 'recorded'
     OR (SELECT state FROM public.outbox_events WHERE id = v_unregistered_id) = 'processing' THEN
    RAISE EXCEPTION 'unroutable events must not reach the processing state';
  END IF;

  -- Release the lease so this probe cannot disturb a later claim pass.
  IF NOT public.complete_outbox_event(v_deliverable_id, 'capability-claim-worker') THEN
    RAISE EXCEPTION 'the owning worker must release the probed delivery lease';
  END IF;
END;
$$;

-- (f2) The availability block edit/delete commands register their event types
-- as recorded-only facts. This is the registry half of the availability block
-- regression: an unregistered type would sit at 'pending' forever, because
-- claim_outbox_delivery_events only leases registered deliverable types and
-- purge_outbox_events only deletes recorded/completed/dead_letter rows.
DO $$
DECLARE
  v_missing text[];
BEGIN
  SELECT array_agg(required.event_type ORDER BY required.event_type) INTO v_missing
  FROM unnest(ARRAY['availability_block.deleted', 'availability_block.updated']) AS required(event_type)
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.outbox_event_delivery_capability AS capability
    WHERE capability.event_type = required.event_type
      AND NOT capability.deliverable
  );
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'availability block command event types must be registered deliverable = false: %', v_missing;
  END IF;

  -- Any row those commands already enqueued in this fixture is recorded, and
  -- none is stranded in the actionable pending backlog.
  IF EXISTS (
    SELECT 1
    FROM public.outbox_events
    WHERE event_type IN ('availability_block.updated', 'availability_block.deleted')
      AND state <> 'recorded'
  ) THEN
    RAISE EXCEPTION 'availability block command events must be recorded, never pending';
  END IF;
END;
$$;

-- (g) Retention now covers recorded rows without disturbing completed/dead_letter.
DO $$
DECLARE
  v_recorded_id uuid;
  v_completed_id uuid;
  v_dead_letter_id uuid;
  v_kept_id uuid;
BEGIN
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'lead.created', 1, 'capability-purge-recorded', '{}'::jsonb
  ) RETURNING id INTO v_recorded_id;
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ai.run.requested', 1, 'capability-purge-completed', '{}'::jsonb
  ) RETURNING id INTO v_completed_id;
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ai.run.requested', 1, 'capability-purge-dead-letter', '{}'::jsonb
  ) RETURNING id INTO v_dead_letter_id;
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'lead.created', 1, 'capability-purge-fresh', '{}'::jsonb
  ) RETURNING id INTO v_kept_id;

  PERFORM id FROM public.claim_outbox_delivery_events('capability-purge-worker', 20, 300)
  WHERE id IN (v_completed_id, v_dead_letter_id);
  IF (SELECT count(*) FROM public.outbox_events
      WHERE id IN (v_completed_id, v_dead_letter_id) AND state = 'processing') <> 2 THEN
    RAISE EXCEPTION 'purge fixtures must first be leased by the delivery worker';
  END IF;

  IF NOT public.complete_outbox_event(v_completed_id, 'capability-purge-worker') THEN
    RAISE EXCEPTION 'the owning worker must complete the leased purge fixture';
  END IF;
  IF public.fail_outbox_event(v_dead_letter_id, 'capability-purge-worker', 'permanent_rejection', 1, 1) <> 'dead_letter' THEN
    RAISE EXCEPTION 'purge fixture must reach dead_letter';
  END IF;
  IF public.complete_outbox_event(v_recorded_id, 'capability-purge-worker') THEN
    RAISE EXCEPTION 'a recorded event must never be completable';
  END IF;

  ALTER TABLE public.outbox_events DISABLE TRIGGER outbox_events_set_updated_at;
  UPDATE public.outbox_events
  SET updated_at = timezone('utc', now()) - interval '10 days'
  WHERE id IN (v_recorded_id, v_completed_id, v_dead_letter_id);
  ALTER TABLE public.outbox_events ENABLE TRIGGER outbox_events_set_updated_at;

  IF public.purge_outbox_events(3600, 100) < 1 THEN
    RAISE EXCEPTION 'purge must remove aged recorded, completed and dead_letter events';
  END IF;
  IF EXISTS (SELECT 1 FROM public.outbox_events WHERE id IN (v_recorded_id, v_completed_id, v_dead_letter_id)) THEN
    RAISE EXCEPTION 'purge must remove every aged terminal-or-recorded event';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.outbox_events WHERE id = v_kept_id) THEN
    RAISE EXCEPTION 'purge must not remove a recorded event inside the retention window';
  END IF;
END;
$$;

-- (h) Tenancy and grant posture for the registry.
DO $$
BEGIN
  IF has_table_privilege('anon', 'public.outbox_event_delivery_capability', 'SELECT')
     OR has_table_privilege('authenticated', 'public.outbox_event_delivery_capability', 'SELECT')
     OR has_table_privilege('anon', 'public.outbox_event_delivery_capability', 'INSERT')
     OR has_table_privilege('authenticated', 'public.outbox_event_delivery_capability', 'INSERT')
     OR has_table_privilege('anon', 'public.outbox_event_delivery_capability', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.outbox_event_delivery_capability', 'UPDATE')
     OR has_table_privilege('anon', 'public.outbox_event_delivery_capability', 'DELETE')
     OR has_table_privilege('authenticated', 'public.outbox_event_delivery_capability', 'DELETE') THEN
    RAISE EXCEPTION 'browser roles must not reach the delivery capability registry';
  END IF;
  IF has_table_privilege('voya_outbox_worker', 'public.outbox_event_delivery_capability', 'SELECT')
     OR has_table_privilege('service_role', 'public.outbox_event_delivery_capability', 'SELECT') THEN
    RAISE EXCEPTION 'the registry must only be read inside the SECURITY DEFINER claim function';
  END IF;
  IF has_function_privilege('authenticated', 'public.claim_outbox_delivery_events(text,integer,integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.claim_outbox_delivery_events(text,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'browser roles must not execute the delivery claim';
  END IF;
  IF NOT has_function_privilege('voya_outbox_worker', 'public.claim_outbox_delivery_events(text,integer,integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.claim_outbox_delivery_events(text,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'the worker and service role must keep delivery claim rights';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.outbox_event_delivery_capability'::regclass)
     OR NOT (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.outbox_event_delivery_capability'::regclass) THEN
    RAISE EXCEPTION 'the delivery capability registry must have forced row level security';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.outbox_events'::regclass
      AND conname = 'outbox_events_state_check'
      AND pg_get_constraintdef(oid) LIKE '%recorded%'
  ) THEN
    RAISE EXCEPTION 'the outbox state check must admit recorded';
  END IF;
END;
$$;

-- Live denial, not just catalog introspection: switch into each browser role
-- and prove the registry read is refused.
DO $$
DECLARE
  v_seen integer;
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    SELECT count(*) INTO v_seen FROM public.outbox_event_delivery_capability;
    RAISE EXCEPTION 'authenticated must not read the delivery capability registry';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  EXECUTE 'RESET ROLE';
END;
$$;

DO $$
DECLARE
  v_seen integer;
BEGIN
  EXECUTE 'SET LOCAL ROLE anon';
  BEGIN
    SELECT count(*) INTO v_seen FROM public.outbox_event_delivery_capability;
    RAISE EXCEPTION 'anon must not read the delivery capability registry';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  EXECUTE 'RESET ROLE';
END;
$$;

-- Later suites assert exact per-organization outbox counts (for example
-- "AI run request must enqueue exactly one outbox event"), so these probes
-- must not survive into the shared disposable schema.
DO $$
DECLARE
  v_removed integer;
BEGIN
  DELETE FROM public.outbox_events WHERE dedupe_key LIKE 'capability-%';
  GET DIAGNOSTICS v_removed = ROW_COUNT;
  IF v_removed < 1 THEN
    RAISE EXCEPTION 'capability probes must be removable from the shared fixture';
  END IF;
END;
$$;

SELECT 'Outbox delivery capability registry integration tests passed' AS result;