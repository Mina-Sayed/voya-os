-- Voya OS V1 property inventory contract checks.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('public.property_images') IS NULL THEN
    RAISE EXCEPTION 'property_images table is required';
  END IF;
  IF to_regprocedure('public.create_property_v1(uuid,text,text,text,text,text,text,integer,integer,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'create_property_v1 RPC is missing';
  END IF;
  IF to_regprocedure('public.update_property_v1(uuid,uuid,text,text,text,text,text,text,integer,integer,text,text,integer,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'update_property_v1 RPC is missing';
  END IF;
  IF to_regprocedure('public.list_properties_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'list_properties_v1 RPC is missing';
  END IF;
  IF to_regprocedure('public.create_property_owner_v1(uuid,text,text,text,text,text,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'create_property_owner_v1 RPC is missing';
  END IF;
  IF to_regprocedure('public.assign_property_owner_v1(uuid,uuid,uuid,date,date,boolean,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'assign_property_owner_v1 RPC is missing';
  END IF;
  IF to_regprocedure('public.update_property_owner_v1(uuid,uuid,text,text,text,text,text,text,text,integer,text,uuid)') IS NULL
    OR to_regprocedure('public.archive_property_owner_v1(uuid,uuid,text,integer,text,uuid)') IS NULL
    OR to_regprocedure('public.restore_property_owner_v1(uuid,uuid,integer,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'property owner lifecycle RPCs are missing';
  END IF;
  IF to_regprocedure('public.register_property_image_v1(uuid,uuid,text,text,bigint,integer,integer,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'register_property_image_v1 RPC is missing';
  END IF;
  IF to_regprocedure('public.list_property_images_v1(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'list_property_images_v1 RPC is missing';
  END IF;
  IF to_regprocedure('public.archive_property_image_v1(uuid,uuid,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'archive_property_image_v1 RPC is missing';
  END IF;
END;
$$;

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.properties', 'INSERT')
    OR has_table_privilege('authenticated', 'public.properties', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.properties', 'DELETE') THEN
    RAISE EXCEPTION 'authenticated must not receive direct property writes';
  END IF;
  IF has_table_privilege('authenticated', 'public.property_images', 'INSERT')
    OR has_table_privilege('authenticated', 'public.property_images', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.property_images', 'DELETE') THEN
    RAISE EXCEPTION 'authenticated must not receive direct property image writes';
  END IF;
  IF has_function_privilege('anon', 'public.list_properties_v1(uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.list_properties_v1_extended(uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.list_properties_v1_without_workspace_aal2(uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.list_properties_v1_extended_without_workspace_aal2(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'property AAL2 wrappers must be the only browser-readable entry points';
  END IF;
  -- Every renamed internal implementation must stay revoked from all login
  -- roles; a single missed REVOKE would otherwise leave a silent AAL2 bypass.
  IF EXISTS (
    SELECT 1
    FROM pg_proc AS routine
    JOIN pg_namespace AS schema_name ON schema_name.oid = routine.pronamespace
    WHERE schema_name.nspname = 'public'
      AND routine.proname LIKE '%_without_workspace_aal2'
      AND (
        has_function_privilege('anon', routine.oid, 'EXECUTE')
        OR has_function_privilege('authenticated', routine.oid, 'EXECUTE')
        OR has_function_privilege('service_role', routine.oid, 'EXECUTE')
      )
  ) THEN
    RAISE EXCEPTION 'internal property implementations must remain revoked from every role';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal1', false);

DO $$
BEGIN
  BEGIN
    PERFORM public.list_properties_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'AAL1 property reads must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.list_properties_v1_extended('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'AAL1 extended property reads must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.create_property_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'AAL1-DENIED',
      'AAL1 denied property',
      'Africa/Cairo',
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      'property-v1-aal1-denied',
      'aaaaaaaa-0000-0000-0000-000000000605'
    );
    RAISE EXCEPTION 'AAL1 property writes must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.create_property_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'AAL1-EXT-DENIED',
      'AAL1 denied extended property',
      'Africa/Cairo',
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      false,
      false,
      false,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      'property-v1-aal1-extended-denied',
      'aaaaaaaa-0000-0000-0000-000000000608'
    );
    RAISE EXCEPTION 'AAL1 extended property writes must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.list_property_owners_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'AAL1 property owner reads must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.list_property_images_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001'
    );
    RAISE EXCEPTION 'AAL1 property image reads must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.create_property_owner_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'AAL1 denied owner',
      '+201001234599',
      '+201001234599',
      NULL,
      NULL,
      NULL,
      'property-owner-aal1-denied'
    );
    RAISE EXCEPTION 'AAL1 property owner writes must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  -- Direct PostgREST reads must also fail closed at AAL1: the member policy
  -- now requires a verified MFA session, so an AAL1 member sees zero rows.
  IF (SELECT count(*) FROM public.properties
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') <> 0 THEN
    RAISE EXCEPTION 'AAL1 direct property reads must return no rows';
  END IF;
END;
$$;

SELECT set_config('request.jwt.claim.aal', 'aal2', false);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.properties
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') < 1 THEN
    RAISE EXCEPTION 'AAL2 direct property reads must keep working for members';
  END IF;
END;
$$;

SELECT public.create_property_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'V1-A-101',
  'شقة V1',
  'Africa/Cairo',
  '12 شارع النيل',
  'القاهرة',
  'A-101',
  2,
  4,
  'تجهيز هادئ قبل الوصول',
  'property-v1-create-1',
  'aaaaaaaa-0000-0000-0000-000000000601'
) AS property_id \gset
SELECT set_config('voya.test.property_v1_id', :'property_id', false);

SELECT public.create_property_owner_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'مالك V1',
  '+201000000601',
  '+201000000601',
  'owner-v1@example.test',
  'whatsapp',
  'جهة اتصال تشغيلية',
  'owner-v1-create-1',
  'aaaaaaaa-0000-0000-0000-000000000602'
) AS owner_id \gset
SELECT set_config('voya.test.owner_v1_id', :'owner_id', false);

SELECT public.assign_property_owner_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'property_id',
  :'owner_id',
  DATE '2020-01-01',
  DATE '2100-01-01',
  true,
  'property-v1-owner-period-1',
  'aaaaaaaa-0000-0000-0000-000000000603'
) AS ownership_period_id \gset

SELECT *
FROM public.list_property_owners_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
WHERE id = :'owner_id'
  AND phone = '+201000000601'
  AND whatsapp = '+201000000601'
  AND email = 'owner-v1@example.test'
  AND preferred_contact_method = 'whatsapp';

SELECT public.update_property_owner_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'owner_id',
  'مالك V1 محدث',
  '+201000000602',
  '+201000000602',
  'owner-v1-updated@example.test',
  'phone',
  'ملاحظة محدثة',
  'inactive',
  1,
  'owner-v1-update-1',
  'aaaaaaaa-0000-0000-0000-000000000608'
);

SELECT public.archive_property_owner_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'owner_id', 'تقاعد الجهة المالكة', 2,
  'owner-v1-archive-1', 'aaaaaaaa-0000-0000-0000-000000000609'
);

SELECT public.restore_property_owner_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'owner_id', 3,
  'owner-v1-restore-1', 'aaaaaaaa-0000-0000-0000-000000000610'
);

SELECT count(*)
FROM public.list_property_owners_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
WHERE id = :'owner_id' AND status = 'active' AND version = 4 AND display_name = 'مالك V1 محدث';

SELECT public.register_property_image_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'property_id',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || :'property_id' || '/00000000-0000-0000-0000-000000000601.jpg',
  'image/jpeg',
  524288,
  1024,
  768,
  'property-v1-image-1',
  'aaaaaaaa-0000-0000-0000-000000000604'
) AS image_id \gset

SELECT count(*)
FROM public.list_properties_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
WHERE id = :'property_id'
  AND address = '12 شارع النيل'
  AND city = 'القاهرة'
  AND unit_label = 'A-101'
  AND bedrooms = 2
  AND max_guests = 4
  AND current_property_owner_name = 'مالك V1'
  AND image_count = 1;

SELECT count(*)
FROM public.list_property_images_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'property_id')
WHERE id = :'image_id'
  AND storage_path = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || :'property_id' || '/00000000-0000-0000-0000-000000000601.jpg'
  AND mime_type = 'image/jpeg';

DO $$
BEGIN
  BEGIN
    PERFORM public.register_property_image_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.property_v1_id')::uuid,
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || current_setting('voya.test.property_v1_id') || '/00000000-0000-0000-0000-000000000602.svg',
      'image/svg+xml',
      100,
      100,
      100,
      'property-v1-image-svg',
      'aaaaaaaa-0000-0000-0000-000000000605'
    );
    RAISE EXCEPTION 'SVG property image must be rejected';
  EXCEPTION WHEN check_violation OR invalid_parameter_value THEN
    NULL;
  END;
END;
$$;

SELECT public.update_property_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  :'property_id',
  'V1-A-101',
  'شقة V1 المحدثة',
  'Africa/Cairo',
  '12 شارع النيل',
  'القاهرة',
  'A-101',
  2,
  4,
  'ملاحظة محدثة',
  'inactive',
  1,
  'property-v1-update-1',
  'aaaaaaaa-0000-0000-0000-000000000606'
);

RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.properties WHERE id = current_setting('voya.test.property_v1_id')::uuid) <> 'inactive'
    OR (SELECT version FROM public.properties WHERE id = current_setting('voya.test.property_v1_id')::uuid) <> 2 THEN
    RAISE EXCEPTION 'property update must persist status and increment version';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE resource_id = current_setting('voya.test.property_v1_id')::uuid AND action = 'property.updated' AND outcome = 'success') <> 1 THEN
    RAISE EXCEPTION 'property update must append audit evidence';
  END IF;
  IF (SELECT count(*) FROM public.outbox_events WHERE event_type = 'property.updated' AND payload->>'property_id' = current_setting('voya.test.property_v1_id')) <> 1 THEN
    RAISE EXCEPTION 'property update must enqueue an outbox event';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_properties_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'cross-tenant property read must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.update_property_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.property_v1_id')::uuid,
      'V1-CROSS-TENANT', 'غير مسموح', 'Africa/Cairo', NULL, NULL, NULL,
      NULL, NULL, NULL, 'active', 2, 'property-v1-cross-tenant',
      'aaaaaaaa-0000-0000-0000-000000000607'
    );
    RAISE EXCEPTION 'cross-tenant property update must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'property inventory V1 tests passed' AS result;
