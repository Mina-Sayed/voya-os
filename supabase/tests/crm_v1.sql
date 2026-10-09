\set ON_ERROR_STOP on

CREATE FUNCTION pg_temp.assert_expected_count(p_actual bigint, p_expected bigint, p_label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_actual <> p_expected THEN
    RAISE EXCEPTION '% expected %, received %', p_label, p_expected, p_actual USING ERRCODE = '23514';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION pg_temp.assert_expected_count(bigint, bigint, text) TO authenticated;

DO $$
BEGIN
  BEGIN
    PERFORM pg_temp.assert_expected_count(0, 1, 'negative assertion self-test');
    RAISE EXCEPTION 'count assertion accepted absent expected data';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$$;

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
SELECT set_config('voya.test.lead_id', :'lead_id', false);

SELECT public.create_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'تكرار محتمل', '+201000000701', NULL, NULL,
  'referral', 'contacted', NULL, 'المعادي', DATE '2027-03-01', DATE '2027-03-03',
  2, 1, NULL, 'تحذير تكرار فقط', NULL,
  'crm-lead-v1-2', 'aaaaaaaa-0000-0000-0000-000000000702'
) AS duplicate_lead_id \gset
SELECT set_config('voya.test.duplicate_lead_id', :'duplicate_lead_id', false);

SELECT pg_temp.assert_expected_count((
  SELECT count(*) FROM public.list_leads_v1_page(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', NULL, NULL, 1
  )
), 1, 'first lead keyset page');
SELECT created_at AS lead_page_cursor_time, id AS lead_page_cursor_id
FROM public.list_leads_v1_page('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', NULL, NULL, 1)
\gset
SELECT pg_temp.assert_expected_count((
  SELECT count(*) FROM public.list_leads_v1_page(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_page_cursor_time', :'lead_page_cursor_id', 1
  )
), 1, 'next lead keyset page');

SELECT public.update_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_id',
  'أحمد عميل جديد', '+201000000701', NULL, 'ahmed-v1@example.test',
  'website', 'new', NULL, 'وسط البلد', DATE '2027-02-01', DATE '2027-02-07',
  3, 2, '50000 EGP', 'طلب مناسب للعائلة', TIMESTAMPTZ '2026-08-20 10:00:00+00',
  1, 'crm-update-v1-1', 'aaaaaaaa-0000-0000-0000-000000000709'
);
DO $$
BEGIN
  BEGIN
    PERFORM public.update_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.lead_id')::uuid,
      'اسم مختلف', '+201000000701', NULL, 'ahmed-v1@example.test',
      'website', 'new', NULL, 'وسط البلد', DATE '2027-02-01', DATE '2027-02-07',
      3, 2, '50000 EGP', 'طلب مناسب للعائلة', TIMESTAMPTZ '2026-08-20 10:00:00+00',
      1, 'crm-update-v1-1', 'aaaaaaaa-0000-0000-0000-000000000710'
    );
    RAISE EXCEPTION 'a lead-update key must reject a changed payload';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
END;
$$;

-- A rollout retry with the same payload can be recovered from the legacy row
-- only while the exact committed version and values remain on the lead.
RESET ROLE;
DELETE FROM public.review_crm_request_bindings
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND command_name = 'lead.update'
  AND idempotency_key = 'crm-update-v1-1';
SET ROLE authenticated;
SELECT public.update_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_id',
  'أحمد عميل جديد', '+201000000701', NULL, 'ahmed-v1@example.test',
  'website', 'new', NULL, 'وسط البلد', DATE '2027-02-01', DATE '2027-02-07',
  3, 2, '50000 EGP', 'طلب مناسب للعائلة', TIMESTAMPTZ '2026-08-20 10:00:00+00',
  1, 'crm-update-v1-1', 'aaaaaaaa-0000-0000-0000-000000000712'
);
RESET ROLE;
SELECT pg_temp.assert_expected_count((
  SELECT count(*) FROM public.review_crm_request_bindings
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND command_name = 'lead.update'
    AND idempotency_key = 'crm-update-v1-1'
    AND resource_id = :'lead_id'::uuid
), 1, 'matching legacy lead update result is rebound');
DELETE FROM public.review_crm_request_bindings
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND command_name = 'lead.update'
  AND idempotency_key = 'crm-update-v1-1';
SET ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.update_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.lead_id')::uuid,
      'Payload changed after legacy commit', '+201000000701', NULL, 'ahmed-v1@example.test',
      'website', 'new', NULL, 'وسط البلد', DATE '2027-02-01', DATE '2027-02-07',
      3, 2, '50000 EGP', 'طلب مناسب للعائلة', TIMESTAMPTZ '2026-08-20 10:00:00+00',
      1, 'crm-update-v1-1', NULL
    );
    RAISE EXCEPTION 'legacy lead update key must reject a payload that differs from the committed row';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
END;
$$;
RESET ROLE;
SET ROLE authenticated;
SELECT public.update_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_id',
  'أحمد عميل جديد', '+201000000701', NULL, 'ahmed-v1@example.test',
  'website', 'new', NULL, 'وسط البلد', DATE '2027-02-01', DATE '2027-02-07',
  3, 2, '50000 EGP', 'طلب مناسب للعائلة', TIMESTAMPTZ '2026-08-20 10:00:00+00',
  1, 'crm-update-v1-1', NULL
);

SELECT pg_temp.assert_expected_count((
  SELECT count(*)
  FROM public.list_leads_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  WHERE id = :'lead_id'
    AND name = 'أحمد عميل جديد'
    AND normalized_phone = '201000000701'
    AND requested_area = 'وسط البلد'
    AND guests = 3
    AND bedrooms = 2
    AND next_follow_up_at = TIMESTAMPTZ '2026-08-20 10:00:00+00'
    AND duplicate_warning = true
), 1, 'lead list projection');

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

SELECT pg_temp.assert_expected_count((
  SELECT count(*) FROM public.list_lead_page_details_v1(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', ARRAY[:'lead_id'::uuid]
  ) AS details
  WHERE details.lead_id = :'lead_id'::uuid
    AND jsonb_array_length(details.activities) = 2
    AND jsonb_array_length(details.follow_ups) = 1
), 1, 'batched lead detail summary');

-- A rollout can encounter a committed legacy conversion key without the new
-- payload binding. Recover only the same lead's still-matching client result.
RESET ROLE;
DELETE FROM public.review_crm_request_bindings
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND command_name = 'lead.convert'
  AND idempotency_key = 'crm-convert-v1-1';
SET ROLE authenticated;
SELECT public.convert_lead_to_client_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_id', 'crm-convert-v1-1',
  'aaaaaaaa-0000-0000-0000-000000000711'
) AS legacy_replay_client_id \gset
RESET ROLE;
SELECT pg_temp.assert_expected_count((
  SELECT count(*) FROM public.review_crm_request_bindings
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND command_name = 'lead.convert'
    AND idempotency_key = 'crm-convert-v1-1'
    AND resource_id = :'lead_id'::uuid
    AND result = to_jsonb(:'client_id'::uuid)
), 1, 'legacy lead conversion result is rebound');
SELECT 1 / CASE WHEN :'legacy_replay_client_id'::uuid = :'client_id'::uuid THEN 1 ELSE 0 END
  AS legacy_conversion_replay_check;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.aal', 'aal1', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_clients_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'AAL1 client listing must be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
SELECT set_config('request.jwt.claim.aal', 'aal2', false);

SELECT pg_temp.assert_expected_count((
  SELECT count(*) FROM public.list_clients_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  WHERE id = :'client_id' AND source_lead_id = :'lead_id'
    AND display_name = 'أحمد عميل جديد' AND phone = '+201000000701'
), 1, 'converted client projection');

SELECT pg_temp.assert_expected_count((
  SELECT count(*) FROM public.list_lead_activities_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_id')
  WHERE activity_type IN ('call', 'status_change') AND lead_id = :'lead_id'
), 2, 'lead activity history');

SELECT pg_temp.assert_expected_count((
  SELECT count(*) FROM public.list_lead_follow_ups_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'lead_id')
  WHERE id = :'follow_up_id' AND status = 'completed'
), 1, 'completed follow-up projection');

RESET ROLE;

INSERT INTO public.crm_activities (organization_id, lead_id, actor_membership_id, activity_type, content)
SELECT 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'duplicate_lead_id'::uuid,
  (SELECT id FROM public.organization_memberships
   WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     AND user_id = '11111111-1111-1111-1111-111111111111'),
  'note', 'bounded detail ' || series.value
FROM generate_series(1, 12) AS series(value);
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
BEGIN
  IF (SELECT jsonb_array_length(details.activities)
      FROM public.list_lead_page_details_v1(
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        ARRAY[current_setting('voya.test.lead_id')::uuid]
      ) AS details) <> 2 THEN
    RAISE EXCEPTION 'detail batch should use the requested lead id, not another lead';
  END IF;
  IF (SELECT jsonb_array_length(details.activities)
      FROM public.list_lead_page_details_v1(
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        ARRAY[current_setting('voya.test.duplicate_lead_id')::uuid]
      ) AS details) <> 10 THEN
    RAISE EXCEPTION 'lead detail page must return ten recent activity rows';
  END IF;
END;
$$;
RESET ROLE;

-- Pre-migration archive retries replay only when version, archived state, and
-- immutable audit evidence prove the exact reason that was originally used.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
SELECT public.create_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'Legacy archive replay fixture', '+201000007777', NULL, 'archive-replay@example.test',
  'website', 'new', NULL, 'المعادي', NULL, NULL, 2, 1, NULL, NULL, NULL,
  'crm-legacy-archive-lead', 'aaaaaaaa-0000-0000-0000-000000000713'
) AS legacy_archive_lead_id \gset
SELECT set_config('voya.test.legacy_archive_lead_id', :'legacy_archive_lead_id', false);
SELECT public.archive_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'legacy_archive_lead_id',
  'سبب الأرشفة القديم', 1, 'crm-legacy-archive', 'aaaaaaaa-0000-0000-0000-000000000714'
);
RESET ROLE;
DELETE FROM public.review_crm_request_bindings
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND command_name = 'lead.archive'
  AND idempotency_key = 'crm-legacy-archive';
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
SELECT public.archive_lead_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'legacy_archive_lead_id',
  'سبب الأرشفة القديم', 1, 'crm-legacy-archive', 'aaaaaaaa-0000-0000-0000-000000000715'
);
RESET ROLE;
SELECT pg_temp.assert_expected_count((
  SELECT count(*) FROM public.review_crm_request_bindings
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND command_name = 'lead.archive'
    AND idempotency_key = 'crm-legacy-archive'
    AND resource_id = :'legacy_archive_lead_id'::uuid
), 1, 'matching legacy lead archive result is rebound');
DELETE FROM public.review_crm_request_bindings
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND command_name = 'lead.archive'
  AND idempotency_key = 'crm-legacy-archive';
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.archive_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.legacy_archive_lead_id')::uuid,
      'سبب مختلف', 1, 'crm-legacy-archive', NULL
    );
    RAISE EXCEPTION 'legacy lead archive key must reject a different reason';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

-- A sales agent cannot mutate or convert another agent's assigned lead just
-- by supplying its UUID. The target row is assigned to a different agent.
INSERT INTO auth.users (id) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000711'),
  ('aaaaaaaa-0000-0000-0000-000000000712')
ON CONFLICT DO NOTHING;
INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000711', 'sales_agent', 'active'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-000000000712', 'sales_agent', 'active')
ON CONFLICT DO NOTHING;
UPDATE public.leads
SET assigned_membership_id = (SELECT id FROM public.organization_memberships WHERE user_id = 'aaaaaaaa-0000-0000-0000-000000000712')
WHERE id = :'lead_id'::uuid;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000711', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.update_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.lead_id')::uuid,
      'أحمد عميل جديد', '+201000000701', NULL, 'ahmed-v1@example.test',
      'website', 'won', NULL, 'وسط البلد', DATE '2027-02-01', DATE '2027-02-07',
      3, 2, '50000 EGP', 'طلب مناسب للعائلة', TIMESTAMPTZ '2026-08-20 10:00:00+00',
      2, 'cross-agent-update', NULL
    );
    RAISE EXCEPTION 'sales agent update of another agent lead must be denied';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.archive_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.lead_id')::uuid,
      'unauthorized', 2, 'cross-agent-archive', NULL
    );
    RAISE EXCEPTION 'sales agent archive of another agent lead must be denied';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.convert_lead_to_client_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      current_setting('voya.test.lead_id')::uuid,
      'cross-agent-convert', NULL
    );
    RAISE EXCEPTION 'sales agent conversion of another agent lead must be denied';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
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
