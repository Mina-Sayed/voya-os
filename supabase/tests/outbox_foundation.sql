-- Transactional outbox storage is private to reviewed server/worker paths.

DO $$
BEGIN
  IF to_regclass('public.outbox_events') IS NULL THEN
    RAISE EXCEPTION 'outbox_events table is required';
  END IF;
  IF has_table_privilege('authenticated', 'public.outbox_events', 'SELECT')
    OR has_table_privilege('authenticated', 'public.outbox_events', 'INSERT')
    OR has_table_privilege('authenticated', 'public.outbox_events', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.outbox_events', 'DELETE') THEN
    RAISE EXCEPTION 'authenticated must not access the outbox directly';
  END IF;
END;
$$;

UPDATE public.outbox_events
SET available_at = timezone('utc', now()) + interval '1 hour'
WHERE state IN ('pending', 'retry_wait');

INSERT INTO public.outbox_events (
  organization_id, event_type, schema_version, dedupe_key, payload
) VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'notification.prepare', 1,
  'lifecycle-complete-test', '{}'::jsonb
);

SELECT id
FROM public.claim_outbox_events('lifecycle-complete-worker', 1, 60)
WHERE dedupe_key = 'lifecycle-complete-test';

DO $$
DECLARE
  event_id uuid;
BEGIN
  SELECT id INTO event_id FROM public.outbox_events WHERE dedupe_key = 'lifecycle-complete-test';
  IF NOT public.complete_outbox_event(event_id, 'lifecycle-complete-worker') THEN
    RAISE EXCEPTION 'the owning worker must complete an active lease';
  END IF;
  IF (SELECT state FROM public.outbox_events WHERE id = event_id) <> 'completed'
     OR (SELECT locked_by FROM public.outbox_events WHERE id = event_id) IS NOT NULL
     OR (SELECT locked_until FROM public.outbox_events WHERE id = event_id) IS NOT NULL THEN
    RAISE EXCEPTION 'completed outbox events must release their lease';
  END IF;
END;
$$;

INSERT INTO public.outbox_events (
  organization_id, event_type, schema_version, dedupe_key, payload
) VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'notification.prepare', 1,
  'lifecycle-retry-test', '{}'::jsonb
);

SELECT id
FROM public.claim_outbox_events('lifecycle-retry-worker-a', 1, 60)
WHERE dedupe_key = 'lifecycle-retry-test';

DO $$
DECLARE
  event_id uuid;
BEGIN
  SELECT id INTO event_id FROM public.outbox_events WHERE dedupe_key = 'lifecycle-retry-test';
  IF public.fail_outbox_event(event_id, 'lifecycle-retry-worker-a', 'provider_timeout', 1, 2) <> 'retry_wait' THEN
    RAISE EXCEPTION 'a retryable failure must schedule retry_wait';
  END IF;
  IF (SELECT attempts FROM public.outbox_events WHERE id = event_id) <> 1
     OR (SELECT last_error_code FROM public.outbox_events WHERE id = event_id) <> 'provider_timeout'
     OR (SELECT locked_by FROM public.outbox_events WHERE id = event_id) IS NOT NULL
     OR (SELECT available_at FROM public.outbox_events WHERE id = event_id) <= timezone('utc', now()) THEN
    RAISE EXCEPTION 'retry_wait must preserve bounded error metadata and release the lease';
  END IF;

  UPDATE public.outbox_events SET available_at = timezone('utc', now()) - interval '1 second' WHERE id = event_id;
  PERFORM id FROM public.claim_outbox_events('lifecycle-retry-worker-b', 1, 60) WHERE id = event_id;
  IF public.fail_outbox_event(event_id, 'lifecycle-retry-worker-b', 'provider_timeout', 1, 2) <> 'dead_letter' THEN
    RAISE EXCEPTION 'the maximum attempt must transition to dead_letter';
  END IF;
  IF (SELECT state FROM public.outbox_events WHERE id = event_id) <> 'dead_letter'
     OR (SELECT locked_by FROM public.outbox_events WHERE id = event_id) IS NOT NULL THEN
    RAISE EXCEPTION 'dead-letter events must release their lease';
  END IF;
END;
$$;

INSERT INTO public.outbox_events (
  organization_id, event_type, schema_version, dedupe_key, payload
) VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'notification.prepare', 1,
  'lifecycle-stale-lease-test', '{}'::jsonb
);

SELECT id
FROM public.claim_outbox_events('lifecycle-stale-worker', 1, 60)
WHERE dedupe_key = 'lifecycle-stale-lease-test';

DO $$
DECLARE
  event_id uuid;
BEGIN
  SELECT id INTO event_id FROM public.outbox_events WHERE dedupe_key = 'lifecycle-stale-lease-test';
  UPDATE public.outbox_events SET locked_until = timezone('utc', now()) - interval '1 second' WHERE id = event_id;
  IF public.complete_outbox_event(event_id, 'lifecycle-stale-worker') THEN
    RAISE EXCEPTION 'an expired worker lease must not complete an event';
  END IF;
  PERFORM id FROM public.claim_outbox_events('lifecycle-reclaimer', 1, 60) WHERE id = event_id;
  IF NOT public.complete_outbox_event(event_id, 'lifecycle-reclaimer') THEN
    RAISE EXCEPTION 'the reclaimed worker must complete the event';
  END IF;
END;
$$;

INSERT INTO public.outbox_events (
  organization_id, event_type, schema_version, dedupe_key, payload
) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'notification.prepare', 1, 'lifecycle-purge-completed', '{}'::jsonb),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'notification.prepare', 1, 'lifecycle-purge-dead-letter', '{}'::jsonb);

SELECT id FROM public.claim_outbox_events('lifecycle-purge-worker', 2, 60);

DO $$
DECLARE
  completed_id uuid;
  dead_letter_id uuid;
BEGIN
  SELECT id INTO completed_id FROM public.outbox_events WHERE dedupe_key = 'lifecycle-purge-completed';
  SELECT id INTO dead_letter_id FROM public.outbox_events WHERE dedupe_key = 'lifecycle-purge-dead-letter';
  PERFORM public.complete_outbox_event(completed_id, 'lifecycle-purge-worker');
  PERFORM public.fail_outbox_event(dead_letter_id, 'lifecycle-purge-worker', 'permanent_rejection', 1, 1);
  ALTER TABLE public.outbox_events DISABLE TRIGGER outbox_events_set_updated_at;
  UPDATE public.outbox_events
  SET updated_at = timezone('utc', now()) - interval '2 hours'
  WHERE id IN (completed_id, dead_letter_id);
  ALTER TABLE public.outbox_events ENABLE TRIGGER outbox_events_set_updated_at;
  IF public.purge_outbox_events(3600, 100) < 2 THEN
    RAISE EXCEPTION 'purge must remove old completed and dead-letter events';
  END IF;
  IF EXISTS (SELECT 1 FROM public.outbox_events WHERE id IN (completed_id, dead_letter_id)) THEN
    RAISE EXCEPTION 'purge must remove only eligible terminal events';
  END IF;
END;
$$;

DO $$
BEGIN
  IF has_function_privilege('authenticated', 'public.claim_outbox_events(text,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must not execute the outbox claim function';
  END IF;
  IF has_function_privilege('anon', 'public.claim_outbox_events(text,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute the outbox claim function';
  END IF;
  IF has_function_privilege('authenticated', 'public.complete_outbox_event(uuid,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fail_outbox_event(uuid,text,text,integer,integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.purge_outbox_events(integer,integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.complete_outbox_event(uuid,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.fail_outbox_event(uuid,text,text,integer,integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.purge_outbox_events(integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'browser roles must not execute outbox lifecycle functions';
  END IF;
  IF NOT has_function_privilege('voya_outbox_worker', 'public.claim_outbox_events(text,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'the dedicated outbox worker must execute the claim function';
  END IF;
  IF NOT has_function_privilege('voya_outbox_worker', 'public.complete_outbox_event(uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('voya_outbox_worker', 'public.fail_outbox_event(uuid,text,text,integer,integer)', 'EXECUTE')
     OR NOT has_function_privilege('voya_outbox_worker', 'public.purge_outbox_events(integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'the dedicated outbox worker must execute lifecycle functions';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'voya_outbox_worker'
      AND NOT rolcanlogin
      AND NOT rolinherit
  ) THEN
    RAISE EXCEPTION 'the dedicated outbox worker must be a NOLOGIN NOINHERIT role';
  END IF;
  IF has_table_privilege('voya_outbox_worker', 'public.outbox_events', 'SELECT')
    OR has_table_privilege('voya_outbox_worker', 'public.outbox_events', 'INSERT')
    OR has_table_privilege('voya_outbox_worker', 'public.outbox_events', 'UPDATE') THEN
    RAISE EXCEPTION 'the outbox worker must not access the outbox table directly';
  END IF;
  IF has_table_privilege('voya_outbox_worker', 'public.outbox_events', 'DELETE') THEN
    RAISE EXCEPTION 'the outbox worker must not access the outbox table directly';
  END IF;
  IF has_table_privilege('anon', 'public.outbox_events', 'SELECT')
    OR has_table_privilege('anon', 'public.outbox_events', 'INSERT')
    OR has_table_privilege('anon', 'public.outbox_events', 'UPDATE')
    OR has_table_privilege('anon', 'public.outbox_events', 'DELETE') THEN
    RAISE EXCEPTION 'anon must not access the outbox directly';
  END IF;
END;
$$;

UPDATE public.outbox_events
SET available_at = timezone('utc', now()) + interval '1 hour',
    locked_until = CASE WHEN state = 'processing' THEN timezone('utc', now()) + interval '1 hour' ELSE NULL END
WHERE state IN ('pending', 'retry_wait', 'processing');

INSERT INTO public.outbox_events (
  organization_id, event_type, schema_version, dedupe_key, payload,
  state, attempts, locked_by, locked_until
) VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'notification.prepare', 1, 'expired-lease-test', '{}'::jsonb,
  'processing', 1, 'crashed-worker', timezone('utc', now()) - interval '1 minute'
);

SELECT id FROM public.claim_outbox_events('recovery-worker', 1, 60);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.outbox_events
      WHERE dedupe_key = 'expired-lease-test'
        AND state = 'processing'
        AND locked_by = 'recovery-worker'
        AND locked_until > timezone('utc', now())
        AND attempts = 2) <> 1 THEN
    RAISE EXCEPTION 'an expired processing lease must be reclaimed exactly once';
  END IF;
END;
$$;

BEGIN;
SET LOCAL TIME ZONE 'Pacific/Honolulu';

UPDATE public.outbox_events
SET available_at = now() + interval '1 day',
    locked_until = CASE WHEN state = 'processing' THEN now() + interval '1 day' ELSE NULL END
WHERE state IN ('pending', 'retry_wait', 'processing');

INSERT INTO public.outbox_events (
  organization_id, event_type, schema_version, dedupe_key, payload,
  state, attempts, locked_by, locked_until
) VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'notification.prepare', 1, 'timezone-active-lease-test', '{}'::jsonb,
  'processing', 7, 'timezone-worker', now() + interval '5 minutes'
);

SELECT id FROM public.claim_outbox_events('timezone-recovery-worker', 1, 60);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.outbox_events
      WHERE dedupe_key = 'timezone-active-lease-test'
        AND state = 'processing'
        AND locked_by = 'timezone-worker'
        AND locked_until > now()
        AND attempts = 7) <> 1 THEN
    RAISE EXCEPTION 'an active lease must not be reclaimed in a non-UTC session';
  END IF;
END;
$$;

ROLLBACK;

UPDATE public.outbox_events
SET available_at = timezone('utc', now()) + interval '1 hour'
WHERE state IN ('pending', 'retry_wait');

INSERT INTO public.outbox_events (
  organization_id, event_type, schema_version, dedupe_key, payload,
  state, attempts, locked_by, locked_until
) VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'notification.prepare', 1, 'active-lease-test', '{}'::jsonb,
  'processing', 7, 'active-worker', timezone('utc', now()) + interval '5 minutes'
);

SELECT id FROM public.claim_outbox_events('recovery-worker', 1, 60);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.outbox_events
      WHERE dedupe_key = 'active-lease-test'
        AND state = 'processing'
        AND locked_by = 'active-worker'
        AND locked_until > timezone('utc', now())
        AND attempts = 7) <> 1 THEN
    RAISE EXCEPTION 'an active processing lease must not be stolen';
  END IF;
END;
$$;

INSERT INTO public.outbox_events (
  organization_id, event_type, schema_version, dedupe_key, payload
) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'notification.prepare', 1, 'claim-test-1', '{}'::jsonb),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'notification.prepare', 1, 'claim-test-2', '{}'::jsonb);

SELECT id
FROM public.claim_outbox_events('worker-a', 1, 60);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.outbox_events
      WHERE state = 'processing'
        AND locked_by = 'worker-a'
        AND locked_until > timezone('utc', now())
        AND attempts = 1) <> 1 THEN
    RAISE EXCEPTION 'claim must atomically lease exactly one eligible event';
  END IF;
END;
$$;

SELECT id
FROM public.claim_outbox_events('worker-b', 10, 60);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.outbox_events
      WHERE state = 'processing'
        AND locked_by = 'worker-b'
        AND attempts = 1) <> 1 THEN
    RAISE EXCEPTION 'second worker must receive only the remaining eligible event';
  END IF;
END;
$$;

INSERT INTO public.outbox_events (
  organization_id, event_type, schema_version, dedupe_key, payload
) VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'property_owner.created',
  1,
  'property-owner:aaaaaaaa-0000-0000-0000-000000000020',
  '{"property_owner_id":"aaaaaaaa-0000-0000-0000-000000000020"}'::jsonb
);

DO $$
BEGIN
  BEGIN
    INSERT INTO public.outbox_events (
      organization_id, event_type, schema_version, dedupe_key, payload
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'property_owner.created', 1,
      'property-owner:aaaaaaaa-0000-0000-0000-000000000020',
      '{}'::jsonb
    );
    RAISE EXCEPTION 'outbox event dedupe key must be unique in its tenant/event type';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.outbox_events (
      organization_id, event_type, schema_version, dedupe_key, payload
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'property_owner.created', 0,
      'invalid-version', '{}'::jsonb
    );
    RAISE EXCEPTION 'outbox schema version must be positive';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$$;
