-- VOYA Stay public catalog and request flow proof. Runs on the disposable DB only.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('public.voya_stay_storefront_config') IS NULL THEN
    RAISE EXCEPTION 'VOYA Stay V1 storefront config table is missing';
  END IF;
  IF to_regclass('public.voya_stay_public_listings') IS NULL
    OR to_regclass('public.voya_stay_public_listing_images') IS NULL
    OR to_regclass('public.voya_stay_request_rate_limits') IS NULL THEN
    RAISE EXCEPTION 'VOYA Stay V1 projection or rate limit table is missing';
  END IF;
  IF to_regprocedure('public.publish_voya_stay_public_listing_v1(uuid,uuid,text,text,text,text,integer,integer,text[],jsonb,text,uuid)') IS NULL
    OR to_regprocedure('public.unpublish_voya_stay_public_listing_v1(uuid,uuid,integer,text,uuid)') IS NULL
    OR to_regprocedure('public.list_voya_stay_public_listings_v1(text,date,date,integer,integer)') IS NULL
    OR to_regprocedure('public.get_voya_stay_public_listing_v1(text,date,date)') IS NULL
    OR to_regprocedure('public.capture_voya_stay_lead_v1(text,text,text,text,date,date,integer,text,text,boolean,text,text,text,uuid)') IS NULL
    OR to_regprocedure('public.list_voya_stay_lead_property_titles_v1(uuid)') IS NULL
    OR to_regprocedure('public.list_voya_stay_publication_states_v1(uuid)') IS NULL
    OR to_regprocedure('public.get_voya_stay_public_request_config_v1()') IS NULL
    OR to_regprocedure('public.list_voya_stay_media_cleanup_v1(uuid,uuid)') IS NULL
    OR to_regprocedure('public.complete_voya_stay_media_cleanup_v1(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'VOYA Stay V1 RPC contract is incomplete';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.voya_stay_storefront_config
    WHERE singleton = true AND organization_id IS NULL
      AND storefront_enabled = false AND requests_enabled = false
  ) THEN
    RAISE EXCEPTION 'VOYA Stay V1 must start unassigned and disabled';
  END IF;
  IF has_table_privilege('anon', 'public.voya_stay_storefront_config', 'SELECT')
    OR has_table_privilege('authenticated', 'public.voya_stay_storefront_config', 'SELECT')
    OR has_table_privilege('anon', 'public.voya_stay_public_listings', 'SELECT')
    OR has_table_privilege('authenticated', 'public.voya_stay_public_listings', 'SELECT')
    OR has_table_privilege('anon', 'public.voya_stay_public_listing_images', 'SELECT')
    OR has_table_privilege('authenticated', 'public.voya_stay_public_listing_images', 'SELECT')
    OR has_table_privilege('service_role', 'public.voya_stay_storefront_config', 'SELECT')
    OR has_table_privilege('service_role', 'public.voya_stay_public_listings', 'SELECT')
    OR has_table_privilege('service_role', 'public.voya_stay_public_listing_images', 'SELECT') THEN
    RAISE EXCEPTION 'public listing metadata must not receive direct browser table grants';
  END IF;
  IF has_function_privilege('anon', 'public.list_voya_stay_public_listings_v1(text,date,date,integer,integer)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.list_voya_stay_public_listings_v1(text,date,date,integer,integer)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.list_voya_stay_public_listings_v1(text,date,date,integer,integer)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.get_voya_stay_public_listing_v1(text,date,date)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.get_voya_stay_public_listing_v1(text,date,date)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.get_voya_stay_public_listing_v1(text,date,date)', 'EXECUTE')
    OR has_function_privilege('service_role', 'public.publish_voya_stay_public_listing_v1(uuid,uuid,text,text,text,text,integer,integer,text[],jsonb,text,uuid)', 'EXECUTE')
    OR has_function_privilege('service_role', 'public.unpublish_voya_stay_public_listing_v1(uuid,uuid,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.capture_voya_stay_lead_v1(text,text,text,text,date,date,integer,text,text,boolean,text,text,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.capture_voya_stay_lead_v1(text,text,text,text,date,date,integer,text,text,boolean,text,text,text,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.capture_voya_stay_lead_v1(text,text,text,text,date,date,integer,text,text,boolean,text,text,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.get_voya_stay_public_request_config_v1()', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.get_voya_stay_public_request_config_v1()', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.get_voya_stay_public_request_config_v1()', 'EXECUTE')
    OR has_function_privilege('anon', 'public.list_voya_stay_media_cleanup_v1(uuid,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.list_voya_stay_media_cleanup_v1(uuid,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.list_voya_stay_media_cleanup_v1(uuid,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.complete_voya_stay_media_cleanup_v1(uuid,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.complete_voya_stay_media_cleanup_v1(uuid,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.complete_voya_stay_media_cleanup_v1(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'public read and capture RPC grants are not least-privilege';
  END IF;
  IF pg_get_function_result('public.list_voya_stay_public_listings_v1(text,date,date,integer,integer)'::regprocedure) ~* 'uuid' THEN
    RAISE EXCEPTION 'public catalog RPC result must not reveal internal UUIDs';
  END IF;
  IF to_regclass('storage.objects') IS NOT NULL AND (
    SELECT count(DISTINCT policyname) FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND permissive = 'RESTRICTIVE'
      AND roles::text[] @> ARRAY['anon', 'authenticated']
      AND policyname IN (
        'voya_stay_public_media_no_browser_insert',
        'voya_stay_public_media_no_browser_update',
        'voya_stay_public_media_no_browser_delete'
      )
  ) <> 3 THEN
    RAISE EXCEPTION 'public media writes must be denied to browser roles, including under broader permissive storage policies';
  END IF;
END;
$$;

BEGIN;

-- An unconfigured storefront is closed even when called with the service role.
SET LOCAL ROLE service_role;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.list_voya_stay_public_listings_v1(NULL, NULL, NULL, NULL, NULL)) THEN
    RAISE EXCEPTION 'unconfigured storefront must have no public listings';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.get_voya_stay_public_request_config_v1()
    WHERE requests_enabled = false AND privacy_notice_version IS NULL
  ) THEN RAISE EXCEPTION 'unconfigured request UI must be disabled'; END IF;
END;
$$;
RESET ROLE;

-- Seed a private source image in each tenant. Its private object path is never
-- part of the public listing RPC result.
INSERT INTO public.property_images (
  id, organization_id, property_id, storage_path, mime_type, byte_size,
  width_px, height_px, idempotency_key, created_by_membership_id
) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000811', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/aaaaaaaa-0000-0000-0000-000000000001/aaaaaaaa-0000-0000-0000-000000000811.jpg', 'image/jpeg', 2048, 1200, 800, 'stay-source-a-811', (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111')),
  ('bbbbbbbb-0000-0000-0000-000000000811', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/bbbbbbbb-0000-0000-0000-000000000001/bbbbbbbb-0000-0000-0000-000000000811.jpg', 'image/jpeg', 2048, 1200, 800, 'stay-source-b-811', (SELECT id FROM public.organization_memberships WHERE organization_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' AND user_id = '22222222-2222-2222-2222-222222222222'));
INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '22222222-2222-2222-2222-222222222222', 'operations', 'active');

UPDATE public.voya_stay_storefront_config
SET organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    storefront_enabled = true,
    requests_enabled = false,
    privacy_notice_url = 'https://example.test/privacy',
    privacy_notice_version = 'test-v1'
WHERE singleton = true;

-- AAL1, wrong-tenant, and wrong-role callers must not publish.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claim.aal', 'aal1', true);
DO $$
BEGIN
  BEGIN
    PERFORM public.publish_voya_stay_public_listing_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001',
      'stay-test-a', 'اختبار إقامة', 'وصف معتمد', 'المعادي', 2, 4, ARRAY['wifi'],
      '[{"source_image_id":"aaaaaaaa-0000-0000-0000-000000000811","public_storage_path":"8f85a3b4-4f3e-4abc-a361-2ca89c4a0892.webp","position":0}]'::jsonb,
      'stay-publish-aal1', 'aaaaaaaa-0000-0000-0000-000000000812'
    );
    RAISE EXCEPTION 'AAL1 property publication must be denied';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
SELECT set_config('request.jwt.claim.aal', 'aal2', true);
DO $$
BEGIN
  BEGIN
    PERFORM public.publish_voya_stay_public_listing_v1(
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'bbbbbbbb-0000-0000-0000-000000000001',
      'stay-test-b', 'اختبار مؤسسة أخرى', 'وصف', 'دبي', 2, 4, ARRAY['wifi'],
      '[{"source_image_id":"bbbbbbbb-0000-0000-0000-000000000811","public_storage_path":"df85a3b4-4f3e-4abc-a361-2ca89c4a0892.webp","position":0}]'::jsonb,
      'stay-publish-cross-tenant', 'aaaaaaaa-0000-0000-0000-000000000813'
    );
    RAISE EXCEPTION 'another organization must not publish into the designated storefront';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
DO $$
BEGIN
  BEGIN
    PERFORM public.publish_voya_stay_public_listing_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001',
      'stay-wrong-image', 'إقامة غير صالحة', 'وصف', 'المعادي', 2, 4, ARRAY['wifi'],
      '[{"source_image_id":"bbbbbbbb-0000-0000-0000-000000000811","public_storage_path":"ff85a3b4-4f3e-4abc-a361-2ca89c4a0892.webp","position":0}]'::jsonb,
      'stay-publish-wrong-image', 'aaaaaaaa-0000-0000-0000-000000000821'
    );
    RAISE EXCEPTION 'another property image must not be published';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END;
$$;

SELECT public.publish_voya_stay_public_listing_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001',
  'stay-test-a', 'إقامة اختبارية', 'وصف معتمد للنشر', 'المعادي', 2, 4, ARRAY['wifi','kitchen'],
  '[{"source_image_id":"aaaaaaaa-0000-0000-0000-000000000811","public_storage_path":"8f85a3b4-4f3e-4abc-a361-2ca89c4a0892.webp","position":0}]'::jsonb,
  'stay-publish-a-1', 'aaaaaaaa-0000-0000-0000-000000000814'
) ->> 'listing_id' AS published_listing_id \gset
SELECT public.publish_voya_stay_public_listing_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001',
  'stay-test-a', 'إقامة اختبارية', 'وصف معتمد للنشر', 'المعادي', 2, 4, ARRAY['wifi','kitchen'],
  '[{"source_image_id":"aaaaaaaa-0000-0000-0000-000000000811","public_storage_path":"8f85a3b4-4f3e-4abc-a361-2ca89c4a0892.webp","position":0}]'::jsonb,
  'stay-publish-a-1', 'aaaaaaaa-0000-0000-0000-000000000815'
) ->> 'listing_id' AS repeated_listing_id \gset
RESET ROLE;
SELECT 1 / CASE WHEN :'published_listing_id' = :'repeated_listing_id' THEN 1 ELSE 0 END AS publication_idempotency_check;

SET LOCAL ROLE service_role;
DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.list_voya_stay_public_listings_v1(NULL, NULL, NULL, NULL, NULL) AS listing
  WHERE listing.slug = 'stay-test-a'
    AND listing.title = 'إقامة اختبارية'
    AND listing.area_label = 'المعادي'
    AND listing.image_paths = ARRAY['8f85a3b4-4f3e-4abc-a361-2ca89c4a0892.webp']
    AND listing.advisory_available IS NULL;
  IF v_count <> 1 THEN RAISE EXCEPTION 'public RPC did not return the approved allowlisted projection'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.list_voya_stay_public_listings_v1(NULL, DATE '2027-01-01', DATE '2027-01-03', 1, NULL) AS listing
    WHERE listing.slug = 'stay-test-a' AND listing.advisory_available IS NOT TRUE
  ) THEN RAISE EXCEPTION 'unoccupied dates should be advisory-available'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.get_voya_stay_public_listing_v1('stay-test-a', DATE '2027-01-01', DATE '2027-01-03') AS listing
    WHERE listing.title = 'إقامة اختبارية' AND listing.advisory_available IS TRUE
  ) THEN RAISE EXCEPTION 'direct public detail RPC must resolve an allowlisted published listing'; END IF;
END;
$$;

-- A disabled guest-request setting denies capture; enabled requests create only
-- a CRM lead with consent evidence and no booking or occupancy mutation.
DO $$
BEGIN
  BEGIN
    PERFORM public.capture_voya_stay_lead_v1(
      'stay-test-a', 'Test Guest', '+20100000811', 'test811@example.test',
      DATE '2027-01-01', DATE '2027-01-03', 2, 'Testing request', 'test-v1', true,
      repeat('a', 64), repeat('b', 64), '81111111-0000-4000-8000-000000000816', 'aaaaaaaa-0000-0000-0000-000000000816'
    );
    RAISE EXCEPTION 'guest request capture must be closed while requests are disabled';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
  END;
END;
$$;
RESET ROLE;
UPDATE public.voya_stay_storefront_config SET requests_enabled = true WHERE singleton = true;
SELECT count(*) AS bookings_before FROM public.bookings \gset
SELECT count(*) AS occupancies_before FROM public.property_occupancies \gset
SET LOCAL ROLE service_role;
SELECT public.capture_voya_stay_lead_v1(
  'stay-test-a', 'Test Guest', '+20100000811', 'test811@example.test',
  DATE '2027-01-01', DATE '2027-01-03', 2, 'Testing request', 'test-v1', true,
  repeat('a', 64), repeat('b', 64), '81111111-0000-4000-8000-000000000817', 'aaaaaaaa-0000-0000-0000-000000000817'
) AS stay_lead_id \gset
SELECT public.capture_voya_stay_lead_v1(
  'stay-test-a', 'Test Guest', '+20100000811', 'test811@example.test',
  DATE '2027-01-01', DATE '2027-01-03', 2, 'Testing request', 'test-v1', true,
  repeat('a', 64), repeat('b', 64), '81111111-0000-4000-8000-000000000817', 'aaaaaaaa-0000-0000-0000-000000000818'
) AS repeated_stay_lead_id \gset
RESET ROLE;
SELECT 1 / CASE WHEN EXISTS (
  SELECT 1 FROM public.leads
  WHERE id = :'stay_lead_id'::uuid AND source = 'voya_stay'
    AND requested_check_in = DATE '2027-01-01' AND requested_check_out = DATE '2027-01-03'
    AND guests = 2 AND contact_consent_version = 'test-v1' AND contact_consented_at IS NOT NULL
    AND requested_property_id = 'aaaaaaaa-0000-0000-0000-000000000001'
    AND requested_property_title = 'إقامة اختبارية'
) THEN 1 ELSE 0 END AS guest_crm_mapping_check;
SELECT 1 / CASE WHEN :'stay_lead_id' = :'repeated_stay_lead_id' THEN 1 ELSE 0 END AS guest_idempotency_check;
SELECT 1 / CASE WHEN (SELECT count(*) FROM public.bookings) = :'bookings_before'::integer
  AND (SELECT count(*) FROM public.property_occupancies) = :'occupancies_before'::integer
  THEN 1 ELSE 0 END AS no_booking_occupancy_side_effect_check;
SET LOCAL ROLE service_role;
DO $$
BEGIN
  BEGIN
    PERFORM public.capture_voya_stay_lead_v1(
      'stay-test-a', 'Test Guest', '+20100000811', 'test811@example.test',
      DATE '2027-01-01', DATE '2027-01-03', 2, 'Changed payload', 'test-v1', true,
      repeat('a', 64), repeat('c', 64), '81111111-0000-4000-8000-000000000817', 'aaaaaaaa-0000-0000-0000-000000000820'
    );
    RAISE EXCEPTION 'same idempotency key must reject a changed payload';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END;
$$;
DO $$
DECLARE
  v_index integer;
  v_limited boolean;
  v_key text;
BEGIN
  FOR v_index IN 1..6 LOOP
    v_key := gen_random_uuid()::text;
    v_limited := false;
    BEGIN
      PERFORM public.capture_voya_stay_lead_v1(
        'stay-test-a', 'Rate Test Guest', '+20100000812', NULL,
        DATE '2027-01-01', DATE '2027-01-03', 1, NULL, 'test-v1', true,
        repeat('d', 64), lpad(to_hex(v_index), 64, '0'), v_key, gen_random_uuid()
      );
    EXCEPTION WHEN SQLSTATE 'P0002' THEN v_limited := true;
    END;
    IF v_index < 6 AND v_limited THEN
      RAISE EXCEPTION 'guest request rate limit fired before the fixed threshold';
    END IF;
    IF v_index = 6 AND NOT v_limited THEN
      RAISE EXCEPTION 'guest request rate limit did not fire at the fixed threshold';
    END IF;
  END LOOP;
END;
$$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claim.aal', 'aal2', true);
SELECT 1 / CASE WHEN EXISTS (
  SELECT 1 FROM public.list_voya_stay_lead_property_titles_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  WHERE lead_id = :'stay_lead_id'::uuid AND property_title = 'إقامة اختبارية'
) THEN 1 ELSE 0 END AS staff_crm_property_label_check;
SELECT 1 / CASE WHEN EXISTS (
  SELECT 1 FROM public.list_voya_stay_publication_states_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  WHERE property_id = 'aaaaaaaa-0000-0000-0000-000000000001'
    AND slug = 'stay-test-a' AND status = 'published' AND version = 1
) THEN 1 ELSE 0 END AS staff_publication_state_check;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
SELECT set_config('request.jwt.claim.aal', 'aal2', true);
SELECT 1 / CASE WHEN EXISTS (
  SELECT 1 FROM public.list_voya_stay_publication_states_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  WHERE property_id = 'aaaaaaaa-0000-0000-0000-000000000001'
) THEN 1 ELSE 0 END AS operations_cleanup_state_read_check;
DO $$
BEGIN
  BEGIN
    PERFORM public.publish_voya_stay_public_listing_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001',
      'stay-operations-denied', 'لا ينشر العمليات', 'وصف', 'المعادي', 2, 4, ARRAY['wifi'],
      '[{"source_image_id":"aaaaaaaa-0000-0000-0000-000000000811","public_storage_path":"af85a3b4-4f3e-4abc-a361-2ca89c4a0892.webp","position":0}]'::jsonb,
      'stay-publish-operations-denied', 'aaaaaaaa-0000-0000-0000-000000000823'
    );
    RAISE EXCEPTION 'operations role must not publish public listings';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

-- Unpublish hides the listing before media cleanup and returns only its public
-- derivative object path. Private source rows remain unchanged.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claim.aal', 'aal2', true);
SELECT public.unpublish_voya_stay_public_listing_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'published_listing_id'::uuid, 1,
  'stay-unpublish-a-1', 'aaaaaaaa-0000-0000-0000-000000000819'
);
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.list_voya_stay_public_listings_v1(NULL, NULL, NULL, NULL, NULL) WHERE slug = 'stay-test-a') THEN
    RAISE EXCEPTION 'unpublished listing must be absent from public reads';
  END IF;
END;
$$;
SELECT count(*) AS cleanup_count
FROM public.list_voya_stay_media_cleanup_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'published_listing_id'::uuid)
WHERE storage_path = '8f85a3b4-4f3e-4abc-a361-2ca89c4a0892.webp' \gset
SELECT 1 / CASE WHEN :cleanup_count::integer = 1 THEN 1 ELSE 0 END AS media_cleanup_queue_check;
SELECT count(*) AS cross_tenant_cleanup_count
FROM public.list_voya_stay_media_cleanup_v1('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', :'published_listing_id'::uuid) \gset
SELECT 1 / CASE WHEN :cross_tenant_cleanup_count::integer = 0 THEN 1 ELSE 0 END AS media_cleanup_tenant_isolation_check;
SELECT public.complete_voya_stay_media_cleanup_v1('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '00000000-0000-0000-0000-000000000000') AS cross_tenant_cleanup_complete \gset
SELECT 1 / CASE WHEN :cross_tenant_cleanup_complete::boolean IS DISTINCT FROM true THEN 1 ELSE 0 END AS media_cleanup_cross_tenant_delete_denied_check;
RESET ROLE;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.property_images WHERE id = 'aaaaaaaa-0000-0000-0000-000000000811' AND status = 'active') <> 1 THEN
    RAISE EXCEPTION 'unpublishing must preserve the original private image row';
  END IF;
END;
$$;

-- Returning a property to inactive must hide its public projection and enqueue
-- derivative cleanup; restoring it later requires an explicit republish.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claim.aal', 'aal2', true);
SELECT public.publish_voya_stay_public_listing_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000001',
  'stay-test-a', 'إقامة اختبارية', 'وصف معتمد للنشر', 'المعادي', 2, 4, ARRAY['wifi','kitchen'],
  '[{"source_image_id":"aaaaaaaa-0000-0000-0000-000000000811","public_storage_path":"9f85a3b4-4f3e-4abc-a361-2ca89c4a0892.webp","position":0}]'::jsonb,
  'stay-republish-before-inactivation', 'aaaaaaaa-0000-0000-0000-000000000822'
);
RESET ROLE;
UPDATE public.properties SET status = 'inactive'
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND id = 'aaaaaaaa-0000-0000-0000-000000000001';
DO $$
BEGIN
  IF (SELECT status FROM public.voya_stay_public_listings WHERE slug = 'stay-test-a') <> 'unpublished' THEN
    RAISE EXCEPTION 'inactivating a property must automatically hide its public listing';
  END IF;
  IF EXISTS (SELECT 1 FROM public.voya_stay_public_listing_images WHERE storage_path = '9f85a3b4-4f3e-4abc-a361-2ca89c4a0892.webp') THEN
    RAISE EXCEPTION 'inactivating a property must remove derivative metadata';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.voya_stay_public_media_cleanup WHERE storage_path = '9f85a3b4-4f3e-4abc-a361-2ca89c4a0892.webp') THEN
    RAISE EXCEPTION 'inactivating a property must enqueue derivative cleanup';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.list_voya_stay_publication_states_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') AS publication
    WHERE publication.property_id = 'aaaaaaaa-0000-0000-0000-000000000001'
      AND publication.status = 'unpublished' AND publication.pending_media_cleanup = true
  ) THEN RAISE EXCEPTION 'staff publication state must reveal pending derivative cleanup'; END IF;
  IF (SELECT count(*) FROM public.property_images WHERE id = 'aaaaaaaa-0000-0000-0000-000000000811' AND status = 'active') <> 1 THEN
    RAISE EXCEPTION 'inactivating a property must preserve private source image metadata';
  END IF;
END;
$$;

ROLLBACK;
SELECT 'VOYA Stay public V1 database integration tests passed' AS result;
