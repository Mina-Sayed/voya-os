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
