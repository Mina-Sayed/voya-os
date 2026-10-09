-- Regression proofs for CRM write scope and payload-bound command retries.
\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.update_lead_v1(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer,text,uuid)') IS NULL
    OR to_regprocedure('public.archive_lead_v1(uuid,uuid,text,integer,text,uuid)') IS NULL
    OR to_regprocedure('public.convert_lead_to_client_v1(uuid,uuid,text,uuid)') IS NULL
    OR to_regprocedure('public.create_lead_activity_v1(uuid,uuid,text,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'expected CRM lead write RPC signatures are missing';
  END IF;

  IF (SELECT count(*) FROM pg_proc AS procedure
      JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname = 'public'
        AND procedure.proname IN ('update_lead_v1', 'archive_lead_v1', 'convert_lead_to_client_v1', 'create_lead_activity_v1')) <> 4 THEN
    RAISE EXCEPTION 'CRM lead write RPCs must not have unexpected overloads';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.update_lead_v1(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer,text,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.archive_lead_v1(uuid,uuid,text,integer,text,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.convert_lead_to_client_v1(uuid,uuid,text,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.create_lead_activity_v1(uuid,uuid,text,text,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must retain the documented CRM command grants';
  END IF;

  IF has_function_privilege('anon', 'public.update_lead_v1(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.archive_lead_v1(uuid,uuid,text,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.convert_lead_to_client_v1(uuid,uuid,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.create_lead_activity_v1(uuid,uuid,text,text,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute CRM lead write RPCs';
  END IF;

  IF (to_regprocedure('public.update_lead_v1_without_assignment_payload_binding(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer,text,uuid)') IS NOT NULL
      AND (has_function_privilege('authenticated', 'public.update_lead_v1_without_assignment_payload_binding(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer,text,uuid)', 'EXECUTE')
        OR has_function_privilege('anon', 'public.update_lead_v1_without_assignment_payload_binding(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer,text,uuid)', 'EXECUTE')))
    OR (to_regprocedure('public.archive_lead_v1_without_assignment_scope(uuid,uuid,text,integer,text,uuid)') IS NOT NULL
      AND (has_function_privilege('authenticated', 'public.archive_lead_v1_without_assignment_scope(uuid,uuid,text,integer,text,uuid)', 'EXECUTE')
        OR has_function_privilege('anon', 'public.archive_lead_v1_without_assignment_scope(uuid,uuid,text,integer,text,uuid)', 'EXECUTE')))
    OR (to_regprocedure('public.convert_lead_to_client_v1_without_assignment_scope(uuid,uuid,text,uuid)') IS NOT NULL
      AND (has_function_privilege('authenticated', 'public.convert_lead_to_client_v1_without_assignment_scope(uuid,uuid,text,uuid)', 'EXECUTE')
        OR has_function_privilege('anon', 'public.convert_lead_to_client_v1_without_assignment_scope(uuid,uuid,text,uuid)', 'EXECUTE')))
    OR (to_regprocedure('public.create_lead_activity_v1_without_assignment_payload_binding(uuid,uuid,text,text,text,uuid)') IS NOT NULL
      AND (has_function_privilege('authenticated', 'public.create_lead_activity_v1_without_assignment_payload_binding(uuid,uuid,text,text,text,uuid)', 'EXECUTE')
        OR has_function_privilege('anon', 'public.create_lead_activity_v1_without_assignment_payload_binding(uuid,uuid,text,text,text,uuid)', 'EXECUTE')))
    OR (to_regprocedure('public.create_lead_activity_v1_without_lead_scope(uuid,uuid,text,text,text,uuid)') IS NOT NULL
      AND (has_function_privilege('authenticated', 'public.create_lead_activity_v1_without_lead_scope(uuid,uuid,text,text,text,uuid)', 'EXECUTE')
        OR has_function_privilege('anon', 'public.create_lead_activity_v1_without_lead_scope(uuid,uuid,text,text,text,uuid)', 'EXECUTE')))
    OR (to_regprocedure('public.crm_update_lead_payload_hash_v1(uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer)') IS NOT NULL
      AND (has_function_privilege('authenticated', 'public.crm_update_lead_payload_hash_v1(uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer)', 'EXECUTE')
        OR has_function_privilege('anon', 'public.crm_update_lead_payload_hash_v1(uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer)', 'EXECUTE')))
    OR (to_regprocedure('public.crm_create_lead_activity_payload_hash_v1(uuid,text,text)') IS NOT NULL
      AND (has_function_privilege('authenticated', 'public.crm_create_lead_activity_payload_hash_v1(uuid,text,text)', 'EXECUTE')
        OR has_function_privilege('anon', 'public.crm_create_lead_activity_payload_hash_v1(uuid,text,text)', 'EXECUTE'))) THEN
    RAISE EXCEPTION 'private CRM implementations and payload helpers must not be executable by browser roles';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc AS procedure
    JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(procedure.proacl, pg_catalog.acldefault('f', procedure.proowner))
    ) AS privilege
    WHERE namespace.nspname = 'public'
      AND procedure.proname IN (
        'update_lead_v1', 'archive_lead_v1', 'convert_lead_to_client_v1', 'create_lead_activity_v1',
        'update_lead_v1_without_assignment_payload_binding', 'archive_lead_v1_without_assignment_scope',
        'convert_lead_to_client_v1_without_assignment_scope', 'create_lead_activity_v1_without_assignment_payload_binding',
        'create_lead_activity_v1_without_lead_scope',
        'crm_update_lead_payload_hash_v1', 'crm_create_lead_activity_payload_hash_v1'
      )
      AND privilege.grantee = 0
      AND privilege.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'CRM write entrypoints and private helpers must not retain PUBLIC execute';
  END IF;
END;
$$;

INSERT INTO auth.users (id, email, email_confirmed_at)
VALUES
  ('22222222-2222-4222-8222-222222222222', 'crm-remediation-tenant-b-owner@example.test', timezone('utc', now())),
  ('88888888-8888-4888-8888-888888888888', 'crm-remediation-sales@example.test', timezone('utc', now())),
  ('99999999-9999-4999-9999-999999999999', 'crm-remediation-manager@example.test', timezone('utc', now())),
  ('77777777-7777-4777-8777-777777777777', 'crm-remediation-viewer@example.test', timezone('utc', now()))
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, display_name)
VALUES
  ('22222222-2222-4222-8222-222222222222', 'CRM remediation tenant B owner'),
  ('88888888-8888-4888-8888-888888888888', 'CRM remediation sales'),
  ('99999999-9999-4999-9999-999999999999', 'CRM remediation manager'),
  ('77777777-7777-4777-8777-777777777777', 'CRM remediation viewer')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.organizations (id, name, slug)
VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Tenant B', 'tenant-b')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '88888888-8888-4888-8888-888888888888', 'sales_agent', 'active'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '99999999-9999-4999-9999-999999999999', 'manager', 'active'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '77777777-7777-4777-8777-777777777777', 'viewer', 'active'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '22222222-2222-4222-8222-222222222222', 'owner', 'active')
ON CONFLICT (organization_id, user_id) DO UPDATE
SET role = EXCLUDED.role, status = EXCLUDED.status;

WITH fixtures(id, name, assigned_user_id) AS (
  VALUES
    ('aaaaaaaa-0000-0000-0000-000000000a61'::uuid, 'CRM R02 denied update', '11111111-1111-1111-1111-111111111111'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a62'::uuid, 'CRM R02 denied archive', '11111111-1111-1111-1111-111111111111'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a63'::uuid, 'CRM R02 denied convert', '11111111-1111-1111-1111-111111111111'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a64'::uuid, 'CRM R02 unassigned update', NULL::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a65'::uuid, 'CRM R02 self update', '88888888-8888-4888-8888-888888888888'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a66'::uuid, 'CRM R02 unassigned archive', NULL::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a67'::uuid, 'CRM R02 self archive', '88888888-8888-4888-8888-888888888888'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a68'::uuid, 'CRM R02 unassigned convert', NULL::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a69'::uuid, 'CRM R02 self convert', '88888888-8888-4888-8888-888888888888'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a6a'::uuid, 'CRM R02 owner update', '88888888-8888-4888-8888-888888888888'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a6b'::uuid, 'CRM R02 owner archive', '88888888-8888-4888-8888-888888888888'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a6c'::uuid, 'CRM R02 owner convert', '88888888-8888-4888-8888-888888888888'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a6d'::uuid, 'CRM R02 manager update', '88888888-8888-4888-8888-888888888888'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a6e'::uuid, 'CRM R02 manager archive', '88888888-8888-4888-8888-888888888888'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a6f'::uuid, 'CRM R02 manager convert', '88888888-8888-4888-8888-888888888888'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a70'::uuid, 'CRM R02 replay after reassignment', '88888888-8888-4888-8888-888888888888'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a72'::uuid, 'CRM R02 archive replay after reassignment', '88888888-8888-4888-8888-888888888888'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a73'::uuid, 'CRM R02 convert replay after reassignment', '88888888-8888-4888-8888-888888888888'::uuid),
    ('aaaaaaaa-0000-0000-0000-000000000a71'::uuid, 'CRM R16 canonical idempotency', NULL::uuid)
)
INSERT INTO public.leads (
  id, organization_id, title, name, phone, email, normalized_phone, normalized_email,
  source, status, assigned_membership_id, idempotency_key
)
SELECT
  fixtures.id,
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  fixtures.name,
  fixtures.name,
  '+20100000' || right(fixtures.id::text, 4),
  replace(fixtures.id::text, '-', '') || '@crm-remediation.example.test',
  public.crm_normalize_phone('+20100000' || right(fixtures.id::text, 4)),
  public.crm_normalize_email(replace(fixtures.id::text, '-', '') || '@crm-remediation.example.test'),
  'website',
  'new',
  membership.id,
  'crm-assignment-idempotency-fixture:' || fixtures.id::text
FROM fixtures
LEFT JOIN public.organization_memberships AS membership
  ON membership.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
 AND membership.user_id = fixtures.assigned_user_id;

INSERT INTO public.leads (
  id, organization_id, title, name, phone, email, normalized_phone, normalized_email,
  source, status, assigned_membership_id, idempotency_key
)
SELECT
  'bbbbbbbb-0000-0000-0000-000000000a74',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'CRM R02 cross-tenant lead',
  'CRM R02 cross-tenant lead',
  '+201000000074',
  'crm-r02-cross-tenant@example.test',
  public.crm_normalize_phone('+201000000074'),
  public.crm_normalize_email('crm-r02-cross-tenant@example.test'),
  'website', 'new', membership.id, 'crm-assignment-idempotency-cross-tenant'
FROM public.organization_memberships AS membership
WHERE membership.organization_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  AND membership.user_id = '22222222-2222-4222-8222-222222222222';

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
SELECT set_config('request.jwt.claim.sub', '88888888-8888-4888-8888-888888888888', false);

DO $$
BEGIN
  BEGIN
    PERFORM public.update_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a61',
      'Attempted takeover', '+201000000001', NULL, 'takeover-update@example.test',
      'website', 'qualified',
      (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '88888888-8888-4888-8888-888888888888'),
      NULL, NULL, NULL, 2, 1, NULL, 'Should remain untouched', NULL, 1, 'crm-r02-denied-update', NULL
    );
    RAISE EXCEPTION 'sales_agent updated a lead assigned to another member';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;

  BEGIN
    PERFORM public.archive_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a62',
      'attempted archive', 1, 'crm-r02-denied-archive', NULL
    );
    RAISE EXCEPTION 'sales_agent archived a lead assigned to another member';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;

  BEGIN
    PERFORM public.convert_lead_to_client_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a63',
      'crm-r02-denied-convert', NULL
    );
    RAISE EXCEPTION 'sales_agent converted a lead assigned to another member';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;

END;
$$;

-- A successful update is not an authorization capability: assignment may
-- change after the original command, so replay must recheck the locked row.
SELECT public.update_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a70',
  'Replay scoped lead', '+201000000070', NULL, 'replay-scope@example.test',
  'website', 'qualified',
  (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '88888888-8888-4888-8888-888888888888'),
  NULL, NULL, NULL, 2, 1, NULL, 'first accepted update', NULL, 1, 'crm-r02-replay-after-reassignment', NULL
);
SELECT public.archive_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a72',
  'original archive', 1, 'crm-r02-archive-replay-after-reassignment', NULL
);
SELECT public.convert_lead_to_client_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a73',
  'crm-r02-convert-replay-after-reassignment', NULL
);

RESET ROLE;
UPDATE public.leads
SET assigned_membership_id = (
  SELECT id FROM public.organization_memberships
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND user_id = '11111111-1111-1111-1111-111111111111'
)
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000a70';
UPDATE public.leads
SET assigned_membership_id = (
  SELECT id FROM public.organization_memberships
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND user_id = '11111111-1111-1111-1111-111111111111'
)
WHERE id IN ('aaaaaaaa-0000-0000-0000-000000000a72', 'aaaaaaaa-0000-0000-0000-000000000a73');

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '88888888-8888-4888-8888-888888888888', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.update_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a70',
      'Replay scoped lead', '+201000000070', NULL, 'replay-scope@example.test',
      'website', 'qualified',
      (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '88888888-8888-4888-8888-888888888888'),
      NULL, NULL, NULL, 2, 1, NULL, 'first accepted update', NULL, 1, 'crm-r02-replay-after-reassignment', NULL
    );
    RAISE EXCEPTION 'sales_agent replayed a command after losing lead assignment';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;

  BEGIN
    PERFORM public.archive_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a72',
      'original archive', 1, 'crm-r02-archive-replay-after-reassignment', NULL
    );
    RAISE EXCEPTION 'sales_agent replayed archive after losing lead assignment';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;

  BEGIN
    PERFORM public.convert_lead_to_client_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a73',
      'crm-r02-convert-replay-after-reassignment', NULL
    );
    RAISE EXCEPTION 'sales_agent replayed conversion after losing lead assignment';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
END;
$$;

DO $$
BEGIN
  BEGIN
    PERFORM public.update_lead_v1(
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'bbbbbbbb-0000-0000-0000-000000000a74',
      'Cross tenant update', '+201000000074', NULL, 'crm-r02-cross-tenant@example.test',
      'website', 'qualified', NULL, NULL, NULL, NULL, 2, 1, NULL, NULL, NULL, 1,
      'crm-r02-cross-tenant-update', NULL
    );
    RAISE EXCEPTION 'sales_agent crossed organization boundary for a known lead id';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
END;
$$;

SELECT set_config('request.jwt.claim.sub', '77777777-7777-4777-8777-777777777777', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.update_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a64',
      'Viewer update', '+201000000064', NULL, 'viewer-update@example.test',
      'website', 'qualified', NULL, NULL, NULL, NULL, 2, 1, NULL, NULL, NULL, 1,
      'crm-r02-viewer-denied-update', NULL
    );
    RAISE EXCEPTION 'viewer invoked a CRM lead write command';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
END;
$$;

-- Unassigned and self-assigned work remains writable to sales_agent for all
-- three lead commands.
SELECT set_config('request.jwt.claim.sub', '88888888-8888-4888-8888-888888888888', false);
SELECT public.update_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a64',
  'Unassigned update', '+201000000064', NULL, 'unassigned-update@example.test',
  'website', 'qualified', NULL, NULL, NULL, NULL, 2, 1, NULL, NULL, NULL, 1,
  'crm-r02-unassigned-update', NULL
);
SELECT public.update_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a65',
  'Self update', '+201000000065', NULL, 'self-update@example.test',
  'website', 'qualified',
  (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '88888888-8888-4888-8888-888888888888'),
  NULL, NULL, NULL, 2, 1, NULL, NULL, NULL, 1, 'crm-r02-self-update', NULL
);
SELECT public.archive_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a66',
  'unassigned permitted', 1, 'crm-r02-unassigned-archive', NULL
);
SELECT public.archive_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a67',
  'self permitted', 1, 'crm-r02-self-archive', NULL
);
SELECT public.convert_lead_to_client_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a68',
  'crm-r02-unassigned-convert', NULL
);
SELECT public.convert_lead_to_client_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a69',
  'crm-r02-self-convert', NULL
);

-- Owners and managers keep their oversight authority over assigned leads.
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.update_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a6a',
  'Owner update', '+20100000006a', NULL, 'owner-update@example.test',
  'website', 'qualified',
  (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '88888888-8888-4888-8888-888888888888'),
  NULL, NULL, NULL, 2, 1, NULL, NULL, NULL, 1, 'crm-r02-owner-update', NULL
);
SELECT public.archive_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a6b',
  'owner oversight', 1, 'crm-r02-owner-archive', NULL
);
SELECT public.convert_lead_to_client_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a6c',
  'crm-r02-owner-convert', NULL
);

SELECT set_config('request.jwt.claim.sub', '99999999-9999-4999-9999-999999999999', false);
SELECT public.update_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a6d',
  'Manager update', '+20100000006d', NULL, 'manager-update@example.test',
  'website', 'qualified',
  (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '88888888-8888-4888-8888-888888888888'),
  NULL, NULL, NULL, 2, 1, NULL, NULL, NULL, 1, 'crm-r02-manager-update', NULL
);
SELECT public.archive_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a6e',
  'manager oversight', 1, 'crm-r02-manager-archive', NULL
);
SELECT public.convert_lead_to_client_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a6f',
  'crm-r02-manager-convert', NULL
);

-- Exact update replay is stable; changed fields under the same key conflict.
SELECT set_config('request.jwt.claim.sub', '88888888-8888-4888-8888-888888888888', false);
DO $$
DECLARE v_update_result boolean;
BEGIN
  v_update_result := public.update_lead_v1(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a71',
    'Canonical CRM Update', '+201000000071', NULL, 'canonical-update@example.test',
    'website', 'qualified', NULL, 'Cairo', DATE '2027-07-01', DATE '2027-07-04',
    2, 1, '5000 EGP', 'Initial notes', TIMESTAMPTZ '2027-06-20 10:00:00+00', 1,
    'crm-r16-update-key', 'aaaaaaaa-0000-0000-0000-000000000a81'
  );
  IF v_update_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'first update command did not report success';
  END IF;

  v_update_result := public.update_lead_v1(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a71',
    'Canonical CRM Update', '+201000000071', NULL, 'canonical-update@example.test',
    'website', 'qualified', NULL, 'Cairo', DATE '2027-07-01', DATE '2027-07-04',
    2, 1, '5000 EGP', 'Initial notes', TIMESTAMPTZ '2027-06-20 10:00:00+00', 1,
    'crm-r16-update-key', 'aaaaaaaa-0000-0000-0000-000000000a82'
  );
  IF v_update_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'exact update replay did not return the original success';
  END IF;

  BEGIN
    PERFORM public.update_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a71',
      'Changed CRM Update', '+201000000071', NULL, 'canonical-update@example.test',
      'website', 'qualified', NULL, 'Cairo', DATE '2027-07-01', DATE '2027-07-04',
      2, 1, '5000 EGP', 'Initial notes', TIMESTAMPTZ '2027-06-20 10:00:00+00', 1,
      'crm-r16-update-key', NULL
    );
    RAISE EXCEPTION 'changed update name under a reused key reported success';
  EXCEPTION WHEN SQLSTATE '23505' THEN NULL;
  END;

  BEGIN
    PERFORM public.update_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a71',
      'Canonical CRM Update', '+201000000071', NULL, 'canonical-update@example.test',
      'website', 'qualified', NULL, 'Cairo', DATE '2027-07-01', DATE '2027-07-04',
      2, 1, '5000 EGP', 'Changed notes', TIMESTAMPTZ '2027-06-20 10:00:00+00', 1,
      'crm-r16-update-key', NULL
    );
    RAISE EXCEPTION 'changed update notes under a reused key reported success';
  EXCEPTION WHEN SQLSTATE '23505' THEN NULL;
  END;
END;
$$;

DO $$
DECLARE v_first_activity uuid; v_replayed_activity uuid;
BEGIN
  v_first_activity := public.create_lead_activity_v1(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a71',
    'note', 'Original activity content', 'crm-r16-activity-key',
    'aaaaaaaa-0000-0000-0000-000000000a83'
  );
  v_replayed_activity := public.create_lead_activity_v1(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a71',
    'note', 'Original activity content', 'crm-r16-activity-key',
    'aaaaaaaa-0000-0000-0000-000000000a84'
  );
  IF v_first_activity IS DISTINCT FROM v_replayed_activity THEN
    RAISE EXCEPTION 'exact activity replay did not return its original result id';
  END IF;

  BEGIN
    PERFORM public.create_lead_activity_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a71',
      'call', 'Original activity content', 'crm-r16-activity-key', NULL
    );
    RAISE EXCEPTION 'changed activity type under a reused key reported success';
  EXCEPTION WHEN SQLSTATE '23505' THEN NULL;
  END;

  BEGIN
    PERFORM public.create_lead_activity_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000a71',
      'note', 'Changed activity content', 'crm-r16-activity-key', NULL
    );
    RAISE EXCEPTION 'changed activity content under a reused key reported success';
  EXCEPTION WHEN SQLSTATE '23505' THEN NULL;
  END;
END;
$$;

RESET ROLE;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.leads
    WHERE id IN (
      'aaaaaaaa-0000-0000-0000-000000000a61',
      'aaaaaaaa-0000-0000-0000-000000000a62',
      'aaaaaaaa-0000-0000-0000-000000000a63'
    ) AND (version <> 1 OR archived_at IS NOT NULL OR converted_client_id IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'denied CRM commands changed a hidden lead';
  END IF;

  IF (SELECT count(*) FROM public.leads
      WHERE (id = 'aaaaaaaa-0000-0000-0000-000000000a70'
          AND version = 2
          AND assigned_membership_id = (
            SELECT id FROM public.organization_memberships
            WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
              AND user_id = '11111111-1111-1111-1111-111111111111'
          ))
        OR (id = 'aaaaaaaa-0000-0000-0000-000000000a72'
          AND archived_at IS NOT NULL AND version = 2
          AND assigned_membership_id = (
            SELECT id FROM public.organization_memberships
            WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
              AND user_id = '11111111-1111-1111-1111-111111111111'
          ))
        OR (id = 'aaaaaaaa-0000-0000-0000-000000000a73'
          AND converted_client_id IS NOT NULL AND version = 2
          AND assigned_membership_id = (
            SELECT id FROM public.organization_memberships
            WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
              AND user_id = '11111111-1111-1111-1111-111111111111'
          ))
    ) <> 3 THEN
    RAISE EXCEPTION 'CRM replay probes did not preserve post-reassignment state';
  END IF;

  IF (SELECT count(*) FROM public.clients
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND source_lead_id IN (
          'aaaaaaaa-0000-0000-0000-000000000a68',
          'aaaaaaaa-0000-0000-0000-000000000a69',
          'aaaaaaaa-0000-0000-0000-000000000a73',
          'aaaaaaaa-0000-0000-0000-000000000a6c',
          'aaaaaaaa-0000-0000-0000-000000000a6f'
        )) <> 5 THEN
    RAISE EXCEPTION 'permitted conversion paths did not create exactly five clients';
  END IF;

  IF (SELECT count(*) FROM public.clients
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND source_lead_id = 'aaaaaaaa-0000-0000-0000-000000000a63') <> 0 THEN
    RAISE EXCEPTION 'denied conversion created a client';
  END IF;

  IF (SELECT count(*) FROM public.crm_activities
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND lead_id = 'aaaaaaaa-0000-0000-0000-000000000a71'
        AND activity_type = 'note' AND content = 'Original activity content') <> 1 THEN
    RAISE EXCEPTION 'activity replay did not persist exactly one original activity';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.leads
    WHERE id = 'aaaaaaaa-0000-0000-0000-000000000a71'
      AND (name <> 'Canonical CRM Update' OR notes <> 'Initial notes' OR version <> 2)
  ) THEN
    RAISE EXCEPTION 'changed update replay overwrote the first accepted payload';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'crm_v1_command_idempotency'
      AND column_name = 'payload_hash'
  ) THEN
    RAISE EXCEPTION 'CRM idempotency rows must store a canonical payload hash';
  END IF;

  IF (SELECT count(*) FROM public.crm_v1_command_idempotency
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND ((command = 'lead.update' AND idempotency_key = 'crm-r16-update-key')
          OR (command = 'lead.activity.create' AND idempotency_key = 'crm-r16-activity-key'))
        AND payload_hash ~ '^[0-9a-f]{64}$') <> 2 THEN
    RAISE EXCEPTION 'update and activity idempotency rows must persist SHA-256 payload hashes';
  END IF;
END;
$$;

ROLLBACK;

SELECT 'CRM assignment and payload idempotency remediation tests passed' AS result;
