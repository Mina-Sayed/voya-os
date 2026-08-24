-- Regression proof for Codex P1: an AI-confirmed property image must never
-- become an active source-of-record row unless its intake input is mapped in
-- the same PostgreSQL transaction.

DO $$
DECLARE
  v_actor uuid;
  v_draft_id constant uuid := 'aaaaaaaa-0000-4000-8000-00000000a441';
  v_input_id constant uuid := 'aaaaaaaa-0000-4000-8000-00000000a442';
  v_property_id constant uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
BEGIN
  SELECT id INTO v_actor
  FROM public.organization_memberships
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND user_id = '11111111-1111-1111-1111-111111111111'
    AND status = 'active';
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'atomic image test actor fixture is missing';
  END IF;

  DELETE FROM public.ai_data_entry_inputs
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND id = v_input_id;
  DELETE FROM public.ai_data_entry_drafts
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND id = v_draft_id;
  DELETE FROM public.property_images
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND idempotency_key = 'ai-data-entry:aaaaaaaa-0000-4000-8000-00000000a441:property:0:image:aaaaaaaa-0000-4000-8000-00000000a442';

  INSERT INTO public.ai_data_entry_drafts (
    id, organization_id, created_by_membership_id, confirmed_by_membership_id,
    status, source_text, source_kind, extraction_payload, confirmation_payload,
    application_result, idempotency_key, version, expires_at, confirmed_at,
    confirmation_execution_token, confirmation_execution_claimed_at,
    confirmation_execution_heartbeat_at
  ) VALUES (
    v_draft_id,
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    v_actor,
    v_actor,
    'confirmed',
    'atomic image proof',
    'image',
    '{"clients":[],"properties":[]}'::jsonb,
    jsonb_build_object(
      'clients', '[]'::jsonb,
      'properties', jsonb_build_array(jsonb_build_object(
        'code', 'ATOMIC-IMAGE',
        'name', 'Atomic image property',
        'timezone', 'Africa/Cairo',
        'address', NULL,
        'city', NULL,
        'unitLabel', NULL,
        'bedrooms', NULL,
        'maxGuests', NULL,
        'operationalNotes', NULL,
        'imageInputIds', jsonb_build_array(v_input_id::text),
        'confidence', 'high',
        'missingRequired', '[]'::jsonb
      )),
      'unresolved', '[]'::jsonb,
      'warnings', '[]'::jsonb
    ),
    jsonb_build_object(
      'clients', '[]'::jsonb,
      'properties', jsonb_build_array(jsonb_build_object('index', 0, 'recordId', v_property_id::text)),
      'images', '[]'::jsonb
    ),
    'atomic-image-draft',
    7,
    timezone('utc', now()) + interval '1 hour',
    timezone('utc', now()),
    'aaaaaaaa-0000-4000-8000-00000000a443',
    timezone('utc', now()),
    timezone('utc', now())
  );

  INSERT INTO public.ai_data_entry_inputs (
    id, organization_id, draft_id, created_by_membership_id,
    storage_path, mime_type, byte_size, checksum_sha256, idempotency_key, status
  ) VALUES (
    v_input_id,
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    v_draft_id,
    v_actor,
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/aaaaaaaa-0000-4000-8000-00000000a441/aaaaaaaa-0000-4000-8000-00000000a442.png',
    'image/png',
    4,
    NULL,
    'atomic-image-input',
    'active'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.voya_test_fail_atomic_image_mapping()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.id = 'aaaaaaaa-0000-4000-8000-00000000a442'::uuid
    AND NEW.status = 'mapped' THEN
    RAISE EXCEPTION 'forced mapping failure for atomicity proof';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER voya_test_fail_atomic_image_mapping
BEFORE UPDATE ON public.ai_data_entry_inputs
FOR EACH ROW
EXECUTE FUNCTION public.voya_test_fail_atomic_image_mapping();

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.register_property_image_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/aaaaaaaa-0000-0000-0000-000000000001/aaaaaaaa-0000-4000-8000-00000000a442.png',
      'image/png',
      4,
      NULL,
      NULL,
      'ai-data-entry:aaaaaaaa-0000-4000-8000-00000000a441:property:0:image:aaaaaaaa-0000-4000-8000-00000000a442',
      'aaaaaaaa-0000-4000-8000-00000000a444'
    );
    RAISE EXCEPTION 'forced mapping failure should abort AI image registration';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'forced mapping failure should abort AI image registration' THEN
      RAISE;
    END IF;
  END;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF EXISTS (
      SELECT 1 FROM public.property_images
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND idempotency_key = 'ai-data-entry:aaaaaaaa-0000-4000-8000-00000000a441:property:0:image:aaaaaaaa-0000-4000-8000-00000000a442'
    )
    OR (SELECT status FROM public.ai_data_entry_inputs
        WHERE id = 'aaaaaaaa-0000-4000-8000-00000000a442') <> 'active'
    OR EXISTS (
      SELECT 1 FROM public.outbox_events
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND dedupe_key LIKE 'property-image-v1:%'
        AND payload ->> 'storage_path' = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/aaaaaaaa-0000-0000-0000-000000000001/aaaaaaaa-0000-4000-8000-00000000a442.png'
    ) THEN
    RAISE EXCEPTION 'mapping failure must roll back property image, input mapping, and outbox evidence';
  END IF;
END;
$$;

DROP TRIGGER voya_test_fail_atomic_image_mapping ON public.ai_data_entry_inputs;
DROP FUNCTION public.voya_test_fail_atomic_image_mapping();

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
SELECT public.register_property_image_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/aaaaaaaa-0000-0000-0000-000000000001/aaaaaaaa-0000-4000-8000-00000000a442.png',
  'image/png',
  4,
  NULL,
  NULL,
  'ai-data-entry:aaaaaaaa-0000-4000-8000-00000000a441:property:0:image:aaaaaaaa-0000-4000-8000-00000000a442',
  'aaaaaaaa-0000-4000-8000-00000000a445'
) AS atomic_image_id \gset
SELECT public.register_property_image_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/aaaaaaaa-0000-0000-0000-000000000001/aaaaaaaa-0000-4000-8000-00000000a442.png',
  'image/png',
  4,
  NULL,
  NULL,
  'ai-data-entry:aaaaaaaa-0000-4000-8000-00000000a441:property:0:image:aaaaaaaa-0000-4000-8000-00000000a442',
  'aaaaaaaa-0000-4000-8000-00000000a446'
) AS atomic_image_replay_id \gset
RESET ROLE;

SELECT set_config('voya.test.atomic_image_id', :'atomic_image_id', false);
SELECT set_config('voya.test.atomic_image_replay_id', :'atomic_image_replay_id', false);

DO $$
BEGIN
  IF current_setting('voya.test.atomic_image_id') <> current_setting('voya.test.atomic_image_replay_id')
    OR (SELECT status FROM public.ai_data_entry_inputs
        WHERE id = 'aaaaaaaa-0000-4000-8000-00000000a442') <> 'mapped'
    OR (SELECT mapped_property_id FROM public.ai_data_entry_inputs
        WHERE id = 'aaaaaaaa-0000-4000-8000-00000000a442') <> 'aaaaaaaa-0000-0000-0000-000000000001'::uuid
    OR (SELECT count(*) FROM public.property_images
        WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
          AND idempotency_key = 'ai-data-entry:aaaaaaaa-0000-4000-8000-00000000a441:property:0:image:aaaaaaaa-0000-4000-8000-00000000a442') <> 1 THEN
    RAISE EXCEPTION 'successful AI image application must map exactly one idempotent property image';
  END IF;
END;
$$;

SELECT 'AI data-entry image atomicity tests passed' AS result;
