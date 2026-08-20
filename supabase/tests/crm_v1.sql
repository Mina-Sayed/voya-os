\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('public.crm_activities') IS NULL
    OR to_regclass('public.crm_follow_ups') IS NULL
    OR to_regclass('public.crm_v1_command_idempotency') IS NULL THEN
    RAISE EXCEPTION 'CRM V1 tables are missing';
  END IF;
  IF to_regprocedure('public.create_lead_v1(uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,text,uuid)') IS NULL
    OR to_regprocedure('public.list_leads_v1(uuid)') IS NULL
    OR to_regprocedure('public.create_lead_activity_v1(uuid,uuid,text,text,text,uuid)') IS NULL
    OR to_regprocedure('public.create_lead_follow_up_v1(uuid,uuid,timestamptz,text,uuid,text,uuid)') IS NULL
    OR to_regprocedure('public.complete_lead_follow_up_v1(uuid,uuid,text,text,uuid)') IS NULL
    OR to_regprocedure('public.convert_lead_to_client_v1(uuid,uuid,text,uuid)') IS NULL
    OR to_regprocedure('public.list_clients_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'CRM V1 RPCs are missing';
  END IF;
END;
$$;

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.crm_activities', 'SELECT')
    OR has_table_privilege('authenticated', 'public.crm_activities', 'INSERT')
    OR has_table_privilege('authenticated', 'public.crm_follow_ups', 'SELECT')
    OR has_table_privilege('authenticated', 'public.crm_follow_ups', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must not receive direct CRM activity/follow-up table grants';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'أحمد عميل جديد', '+201000000701', NULL, 'ahmed-v1@example.test',
  'website', 'new', NULL, 'وسط البلد', DATE '2027-02-01', DATE '2027-02-07',
  3, 2, '50000 EGP', 'طلب مناسب للعائلة', TIMESTAMPTZ '2026-08-20 10:00:00+00',
  'crm-lead-v1-1', 'aaaaaaaa-0000-0000-0000-000000000701'
) AS lead_id \gset

SELECT public.create_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'تكرار محتمل', '+201000000701', NULL, NULL,
  'referral', 'contacted', NULL, 'المعادي', DATE '2027-03-01', DATE '2027-03-03',
  2, 1, NULL, 'تحذير تكرار فقط', NULL,
  'crm-lead-v1-2', 'aaaaaaaa-0000-0000-0000-000000000702'
) AS duplicate_lead_id \gset

SELECT count(*)
FROM public.list_leads_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
WHERE id = :'lead_id'
  AND name = 'أحمد عميل جديد'
  AND normalized_phone = '201000000701'
  AND requested_area = 'وسط البلد'
  AND guests = 3
  AND bedrooms = 2
  AND next_follow_up_at = TIMESTAMPTZ '2026-08-20 10:00:00+00'
  AND duplicate_warning = true;

SELECT public.create_lead_activity_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_id', 'call',
  'تم التواصل وتأكيد الفترة المطلوبة', 'crm-activity-v1-1',
  'aaaaaaaa-0000-0000-0000-000000000703'
);

SELECT public.create_lead_follow_up_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_id',
  TIMESTAMPTZ '2026-08-21 11:00:00+00', 'إرسال خيارات عقارات مناسبة', NULL,
  'crm-follow-up-v1-1', 'aaaaaaaa-0000-0000-0000-000000000704'
) AS follow_up_id \gset

SELECT public.complete_lead_follow_up_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'follow_up_id',
  'تم إرسال الخيارات', 'crm-follow-up-complete-v1-1',
  'aaaaaaaa-0000-0000-0000-000000000705'
);

SELECT public.convert_lead_to_client_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_id', 'crm-convert-v1-1',
  'aaaaaaaa-0000-0000-0000-000000000706'
) AS client_id \gset

SELECT public.convert_lead_to_client_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_id', 'crm-convert-v1-1',
  'aaaaaaaa-0000-0000-0000-000000000707'
) AS idempotent_client_id \gset

SELECT count(*)
FROM public.list_clients_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
WHERE id = :'client_id'
  AND source_lead_id = :'lead_id'
  AND display_name = 'أحمد عميل جديد'
  AND phone = '+201000000701';

SELECT count(*)
FROM public.list_lead_activities_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_id')
WHERE activity_type IN ('call', 'status_change') AND lead_id = :'lead_id';

SELECT count(*)
FROM public.list_lead_follow_ups_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_id')
WHERE id = :'follow_up_id' AND status = 'completed';

RESET ROLE;

SELECT 1 / CASE WHEN :'client_id' <> :'idempotent_client_id' THEN 0 ELSE 1 END AS conversion_idempotency_check;
SELECT 1 / CASE WHEN (SELECT status FROM public.leads WHERE id = :'lead_id'::uuid) <> 'won'
  OR NOT EXISTS (
    SELECT 1
    FROM public.clients AS client_record
    WHERE client_record.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND client_record.source_lead_id = :'lead_id'::uuid
      AND client_record.id = (SELECT converted_client_id FROM public.leads WHERE id = :'lead_id'::uuid)
  ) THEN 0 ELSE 1 END AS conversion_state_check;
SELECT 1 / CASE WHEN (SELECT count(*) FROM public.crm_activities WHERE lead_id = :'lead_id'::uuid) <> 2 THEN 0 ELSE 1 END AS conversion_history_check;

SET ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.create_lead_v1(
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Tenant B lead', NULL, NULL, 'b@example.test',
      'website', 'new', NULL, NULL, DATE '2027-01-01', DATE '2027-01-02', 1, 1, NULL, NULL, NULL,
      'crm-cross-tenant', 'aaaaaaaa-0000-0000-0000-000000000708'
    );
    RAISE EXCEPTION 'cross-tenant lead creation must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.list_leads_v1('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
    RAISE EXCEPTION 'cross-tenant lead read must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

RESET ROLE;

SELECT 1 / CASE WHEN (SELECT count(*) FROM public.crm_activities WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND lead_id = :'lead_id'::uuid) <> 2 THEN 0 ELSE 1 END AS activity_tenant_check;
SELECT 1 / CASE WHEN (SELECT count(*) FROM public.audit_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND action = 'lead.converted') <> 1 THEN 0 ELSE 1 END AS conversion_audit_check;
SELECT 1 / CASE WHEN (SELECT count(*) FROM public.outbox_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND event_type = 'lead.converted') <> 1 THEN 0 ELSE 1 END AS conversion_outbox_check;

SELECT 'CRM V1 database integration tests passed' AS result;
