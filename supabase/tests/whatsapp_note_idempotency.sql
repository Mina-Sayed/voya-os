-- Prove the WhatsApp internal-note idempotency upgrade boundary: a legacy row
-- exists before the idempotency migration and the follow-up must backfill its
-- key deterministically, replay it without duplicate evidence, and fail
-- closed for ambiguous historical payloads. Mirrors the K-045 fleet pattern.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF (SELECT idempotency_key FROM public.whatsapp_internal_notes
      WHERE id = 'aaaaaaaa-0000-0000-0000-000000000912')
      <> 'legacy-note:aaaaaaaa-0000-0000-0000-000000000912' THEN
    RAISE EXCEPTION 'legacy note key was not backfilled deterministically';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.whatsapp_internal_notes'::regclass
      AND attname = 'idempotency_key'
      AND attnotnull
  ) THEN
    RAISE EXCEPTION 'note idempotency keys must be NOT NULL after upgrade';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

-- Replaying the backfilled key with the identical payload must return the
-- original row without duplicating audit evidence.
SELECT public.add_whatsapp_internal_note(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000913',
  'Upgrade fixture note',
  'legacy-note:aaaaaaaa-0000-0000-0000-000000000912',
  'aaaaaaaa-0000-0000-0000-000000000993'
) AS note_id \gset

RESET ROLE;

SELECT set_config('voya.test.upgrade_note_id', :'note_id', false);

DO $$
BEGIN
  IF current_setting('voya.test.upgrade_note_id', true) IS DISTINCT FROM 'aaaaaaaa-0000-0000-0000-000000000912' THEN
    RAISE EXCEPTION 'legacy note retry must return its original id';
  END IF;
END;
$$;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.whatsapp_internal_notes
      WHERE idempotency_key = 'legacy-note:aaaaaaaa-0000-0000-0000-000000000912') <> 1 THEN
    RAISE EXCEPTION 'legacy note backfill must preserve one row';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE resource_id = 'aaaaaaaa-0000-0000-0000-000000000912'::uuid
      AND action = 'whatsapp.note.created'
  ) THEN
    RAISE EXCEPTION 'replaying a backfilled note must not duplicate evidence';
  END IF;
END;
$$;

-- Same key with a different payload must fail closed, and missing keys must
-- be rejected as invalid input rather than retried as provider failures.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.add_whatsapp_internal_note(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000913',
      'A different note body for the same key',
      'legacy-note:aaaaaaaa-0000-0000-0000-000000000912',
      'aaaaaaaa-0000-0000-0000-000000000994'
    );
    RAISE EXCEPTION 'note idempotency key reuse with different payload was accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.add_whatsapp_internal_note(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000913',
      'A note without a key',
      NULL,
      'aaaaaaaa-0000-0000-0000-000000000995'
    );
    RAISE EXCEPTION 'note without an idempotency key was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
END;
$$;
RESET ROLE;

-- The legacy four-argument entrypoint must stay defined for history but lose
-- browser execution; the idempotent five-argument RPC is the retry path.
DO $$
BEGIN
  IF has_function_privilege('authenticated', 'public.add_whatsapp_internal_note(uuid,uuid,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'legacy note signature must not be browser-executable';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.add_whatsapp_internal_note(uuid,uuid,text,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'idempotent note signature must be browser-executable';
  END IF;
END;
$$;

SELECT 'whatsapp note idempotency upgrade tests passed' AS result;
