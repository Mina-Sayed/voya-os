-- Owner-only permanent CRM deletion regression suite.
-- This test is transactionally isolated and never touches managed tenant data.
\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.delete_crm_lead_v1(uuid,uuid,integer,text,uuid)') IS NULL
    OR to_regprocedure('public.delete_crm_client_v1(uuid,uuid,integer,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'CRM delete RPCs are missing';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.delete_crm_lead_v1(uuid,uuid,integer,text,uuid)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.delete_crm_client_v1(uuid,uuid,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.delete_crm_lead_v1(uuid,uuid,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.delete_crm_client_v1(uuid,uuid,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('PUBLIC', 'public.delete_crm_lead_v1(uuid,uuid,integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('PUBLIC', 'public.delete_crm_client_v1(uuid,uuid,integer,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'CRM delete function grants are unsafe';
  END IF;
END;
$$;

-- A seeded owner of tenant A is provided by the disposable DB harness.
INSERT INTO public.leads (id, organization_id, title, name, source, status, idempotency_key)
VALUES
 ('aaaaaaaa-0000-0000-0000-000000000f01', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Disposable lead', 'Disposable lead', 'website', 'new', 'crm-delete-disposable'),
 ('aaaaaaaa-0000-0000-0000-000000000f02', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Protected lead', 'Protected lead', 'website', 'new', 'crm-delete-protected'),
 ('aaaaaaaa-0000-0000-0000-000000000f03', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Conversion lead', 'Conversion lead', 'website', 'won', 'crm-delete-conversion');

INSERT INTO public.clients (id, organization_id, display_name, idempotency_key)
VALUES
 ('aaaaaaaa-0000-0000-0000-000000000f04', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Disposable client', 'crm-delete-disposable-client'),
 ('aaaaaaaa-0000-0000-0000-000000000f05', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Protected client', 'crm-delete-protected-client');

UPDATE public.leads
SET converted_client_id='aaaaaaaa-0000-0000-0000-000000000f05'
WHERE id='aaaaaaaa-0000-0000-0000-000000000f03';

INSERT INTO public.crm_activities (organization_id, lead_id, actor_membership_id, activity_type, content)
SELECT 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000f02', m.id, 'note', 'Append-only evidence'
FROM public.organization_memberships AS m
WHERE m.organization_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND m.user_id='11111111-1111-1111-1111-111111111111'
  AND m.role='owner' AND m.status='active';

INSERT INTO auth.users (id,email)
VALUES ('ffffffff-1111-4111-8111-111111111111','crm-delete-nonowner@example.test')
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'ffffffff-1111-4111-8111-111111111111', 'manager', 'active')
ON CONFLICT(organization_id, user_id) DO UPDATE SET role='manager',status='active';

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'ffffffff-1111-4111-8111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);

DO $$
BEGIN
  BEGIN
    PERFORM public.delete_crm_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000f01', 1, 'Disposable lead', NULL);
    RAISE EXCEPTION 'manager deleted a lead';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.delete_crm_client_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000f04', 1, 'Disposable client', NULL);
    RAISE EXCEPTION 'manager deleted a client';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;

SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal1', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.delete_crm_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000f01', 1, 'Disposable lead', NULL);
    RAISE EXCEPTION 'AAL1 deleted a lead';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;

SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.delete_crm_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000f01', 1, 'Wrong confirmation', NULL);
    RAISE EXCEPTION 'incorrect lead name accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.delete_crm_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000f01', 2, 'Disposable lead', NULL);
    RAISE EXCEPTION 'stale lead version accepted';
  EXCEPTION WHEN serialization_failure THEN NULL;
  END;
  BEGIN
    PERFORM public.delete_crm_client_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000f04', 1, 'Wrong confirmation', NULL);
    RAISE EXCEPTION 'incorrect client name accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.delete_crm_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000f02', 1, 'Protected lead', NULL);
    RAISE EXCEPTION 'immutable activity lead deleted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.delete_crm_client_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000f05', 1, 'Protected client', NULL);
    RAISE EXCEPTION 'linked client deleted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.delete_crm_lead_v1(
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
      'aaaaaaaa-0000-0000-0000-000000000f01', 1, 'Disposable lead', NULL);
    RAISE EXCEPTION 'cross-tenant operation accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;

SELECT public.delete_crm_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000f01', 1, 'Disposable lead',
  'aaaaaaaa-0000-0000-0000-000000000f11');
SELECT public.delete_crm_client_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000f04', 1, 'Disposable client',
  'aaaaaaaa-0000-0000-0000-000000000f12');

RESET ROLE;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.leads WHERE id='aaaaaaaa-0000-0000-0000-000000000f01'
  ) OR EXISTS (
    SELECT 1 FROM public.clients WHERE id='aaaaaaaa-0000-0000-0000-000000000f04'
  ) THEN
    RAISE EXCEPTION 'unlinked CRM records were not deleted';
  END IF;
  IF (SELECT count(*) FROM public.leads
      WHERE id='aaaaaaaa-0000-0000-0000-000000000f02')<>1
    OR (SELECT count(*) FROM public.clients
      WHERE id='aaaaaaaa-0000-0000-0000-000000000f05')<>1
    OR (SELECT count(*) FROM public.crm_activities
      WHERE lead_id='aaaaaaaa-0000-0000-0000-000000000f02')<>1 THEN
    RAISE EXCEPTION 'linked/immutable CRM records were altered';
  END IF;
  IF (SELECT count(*) FROM public.audit_events
      WHERE organization_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND action IN ('lead.deleted','client.deleted')
        AND resource_id IN (
          'aaaaaaaa-0000-0000-0000-000000000f01',
          'aaaaaaaa-0000-0000-0000-000000000f04'
        ) AND after_delta ? 'deleted')<>2 THEN
    RAISE EXCEPTION 'PII-free CRM delete audit evidence is missing';
  END IF;
END;
$$;
ROLLBACK;

SELECT 'CRM safe owner delete integration tests passed' AS result;
