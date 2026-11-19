\set ON_ERROR_STOP on

BEGIN;
CREATE FUNCTION pg_temp.check_rejection(command text, expected_state text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE command;
  RAISE EXCEPTION 'Expected SQLSTATE %', expected_state;
EXCEPTION WHEN OTHERS THEN
  IF SQLSTATE <> expected_state THEN RAISE; END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION pg_temp.check_rejection(text, text) TO authenticated;

SELECT set_config('repair.org', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
SELECT set_config('repair.property', 'aaaaaaaa-0000-0000-0000-000000000001', true);
SELECT set_config('repair.client', 'aaaaaaaa-0000-0000-0000-000000000002', true);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aal":"aal2"}', true);

DO $$
DECLARE
  org uuid := current_setting('repair.org')::uuid;
  property uuid := current_setting('repair.property')::uuid;
  block uuid;
  client uuid;
  small uuid;
  first_vehicle uuid;
  next_vehicle uuid;
  trip uuid;
  key1 uuid := 'd4a33734-da72-49ee-9fb8-06273829e2ea';
  key2 uuid := 'f97b77f1-b347-48d4-8fbf-d8383f7963dd';
BEGIN
  IF has_function_privilege('authenticated', 'public.update_availability_block_v1(uuid,uuid,date,date,text,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Unversioned availability update is still callable';
  END IF;
  block := public.create_availability_block(org, property, '2098-02-01', '2098-02-03', 'maintenance', 'repair fixture', 'repair-block');
  PERFORM public.update_availability_block_v2(org, block, '2098-02-01', '2098-02-09', 'maintenance', 'extended', 1);
  PERFORM pg_temp.check_rejection(format(
    'SELECT public.update_availability_block_v2(%L,%L,%L,%L,%L,%L,1)',
    org, block, '2098-02-01', '2098-02-03', 'maintenance', 'stale form'), 'P0001');
  PERFORM pg_temp.check_rejection(format('SELECT public.delete_availability_block_v2(%L,%L,1)',org,block), 'P0001');
  IF NOT EXISTS (SELECT 1 FROM public.list_availability_blocks_v2(org) a WHERE a.id=block AND a.version=2 AND a.end_date='2098-02-09') THEN
    RAISE EXCEPTION 'Latest availability version was lost';
  END IF;
  PERFORM public.delete_availability_block_v2(org, block, 2);

  client := public.create_client_v1(org,'Repair Client',NULL,NULL,NULL,NULL,NULL,NULL,NULL,'repair-client');
  IF public.create_client_v1(org,'Repair Client',NULL,NULL,NULL,NULL,NULL,NULL,NULL,'repair-client') <> client THEN
    RAISE EXCEPTION 'Live client replay no longer returns the original id';
  END IF;
  PERFORM public.delete_crm_client_v1(org, client, 1, 'Repair Client');
  PERFORM pg_temp.check_rejection(format(
    'SELECT public.create_client_v1(%L,%L,NULL,NULL,NULL,NULL,NULL,NULL,NULL,%L)',
    org, 'Repair Client', 'repair-client'), '23505');
  IF public.create_client_v1(org,'Repair Client',NULL,NULL,NULL,NULL,NULL,NULL,NULL,'new-repair-client') = client THEN
    RAISE EXCEPTION 'A fresh create did not receive a fresh id';
  END IF;

  small := public.create_fleet_vehicle_v1(org,'Small','sedan','REPAIR-SMALL',2,'repair-small',NULL);
  first_vehicle := public.create_fleet_vehicle_v1(org,'First','van','REPAIR-FIRST',8,'repair-first',NULL);
  next_vehicle := public.create_fleet_vehicle_v1(org,'Next','van','REPAIR-NEXT',9,'repair-next',NULL);
  trip := public.create_transport_request(org,'airport_transfer','Repair guest','Airport','Hotel','2098-02-10T10:00:00Z',6,'2098-02-10T11:00:00Z',NULL,NULL,'repair-trip',NULL);
  PERFORM pg_temp.check_rejection(format('SELECT public.assign_transport_request(%L,%L,%L,NULL,%L)',org,trip,small,key1), 'P0001');
  PERFORM public.assign_transport_request(org,trip,first_vehicle,NULL,key1);
  PERFORM public.assign_transport_request(org,trip,next_vehicle,NULL,key2);
  PERFORM public.assign_transport_request(org,trip,first_vehicle,NULL,key1);
  PERFORM pg_temp.check_rejection(format('SELECT public.assign_transport_request(%L,%L,%L,NULL,%L)',org,trip,first_vehicle,key2), '23505');
  PERFORM set_config('repair.trip',trip::text,true);
  PERFORM set_config('repair.vehicle',next_vehicle::text,true);
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.transport_requests
    WHERE id=current_setting('repair.trip')::uuid AND vehicle_id=current_setting('repair.vehicle')::uuid
  ) THEN RAISE EXCEPTION 'Old assignment replay changed the selected vehicle'; END IF;
END;
$$;

INSERT INTO public.organizations(id,name,slug,timezone,default_currency,status)
VALUES ('e5f15bad-d295-4b15-a49b-5d2467c1a213','Repair booking','repair-booking','Africa/Cairo','EGP','active');
SELECT set_config('repair.org', 'e5f15bad-d295-4b15-a49b-5d2467c1a213', true);
INSERT INTO public.organization_memberships(organization_id,user_id,role,status)
VALUES (current_setting('repair.org')::uuid,'11111111-1111-1111-1111-111111111111','owner','active');
INSERT INTO public.properties(id,organization_id,code,name,timezone)
VALUES ('eed4d55d-e818-4ade-96d1-487b033caf86',current_setting('repair.org')::uuid,'REPAIR-BOOKING','Repair property','Africa/Cairo');
INSERT INTO public.clients(id,organization_id,display_name)
VALUES ('b976b922-0ab5-4edf-b226-d0ae7f417f47',current_setting('repair.org')::uuid,'Repair booking client');

SET LOCAL ROLE authenticated;
DO $$
BEGIN
  IF public.get_booking_approval_readiness_v1(current_setting('repair.org')::uuid) THEN
    RAISE EXCEPTION 'Single-approver organization appears ready';
  END IF;
END;
$$;
RESET ROLE;
INSERT INTO public.organization_memberships(organization_id,user_id,role,status)
VALUES (current_setting('repair.org')::uuid,'22222222-2222-2222-2222-222222222222','manager','active');

SET LOCAL ROLE authenticated;
DO $$
DECLARE
  org uuid := current_setting('repair.org')::uuid;
  booking uuid;
  approval uuid;
  cancellation uuid;
BEGIN
  IF NOT public.get_booking_approval_readiness_v1(org) THEN RAISE EXCEPTION 'Two active reviewers do not appear ready'; END IF;
  booking := public.create_commercial_booking_draft(org, 'eed4d55d-e818-4ade-96d1-487b033caf86',
    'b976b922-0ab5-4edf-b226-d0ae7f417f47', '2098-03-01','2098-03-03','10000','EGP','repair-booking');
  approval := public.request_commercial_booking_approval(org,booking,'repair-confirm-request');
  PERFORM set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',true);
  PERFORM set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated","aal":"aal2"}',true);
  PERFORM public.decide_booking_approval(org,approval,'approved','booking confirmed');
  PERFORM public.confirm_commercial_booking(org,booking,'repair-confirm');
  PERFORM set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',true);
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aal":"aal2"}',true);
  cancellation := public.request_booking_cancellation(org,booking,'guest cancelled','repair-cancel-request');
  IF cancellation <> public.request_booking_cancellation(org,booking,'guest cancelled','repair-cancel-request') THEN
    RAISE EXCEPTION 'Cancellation request retry generated another approval';
  END IF;
  PERFORM set_config('repair.booking',booking::text,true);
  PERFORM set_config('repair.confirmation',approval::text,true);
  PERFORM set_config('repair.cancellation',cancellation::text,true);
END;
$$;
RESET ROLE;
INSERT INTO public.approval_requests(
  organization_id,resource_type,resource_id,proposed_action,proposal_snapshot,snapshot_hash,requester_membership_id,status,created_at)
SELECT current_setting('repair.org')::uuid, 'booking', current_setting('repair.booking')::uuid,'booking.confirm','{}'::jsonb,
  encode(extensions.digest('{}','sha256'),'hex'), m.id,'rejected',clock_timestamp()+interval '1 day'
FROM public.organization_memberships AS m CROSS JOIN generate_series(1,51)
WHERE m.organization_id=current_setting('repair.org')::uuid AND m.user_id='11111111-1111-1111-1111-111111111111';

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',true);
SELECT set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated","aal":"aal2"}',true);
DO $$
DECLARE
  org uuid := current_setting('repair.org')::uuid;
  booking uuid := current_setting('repair.booking')::uuid;
  cancellation uuid := current_setting('repair.cancellation')::uuid;
  first_row record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.list_approval_requests_v3(org,50,true) q WHERE q.id=cancellation) THEN
    RAISE EXCEPTION 'Recent decision history hid a pending cancellation';
  END IF;
  SELECT * INTO first_row FROM public.list_approval_requests_v3(org,50,false) LIMIT 1;
  IF EXISTS (SELECT 1 FROM public.list_approval_requests_v3(org,51,false,first_row.created_at,first_row.id) q WHERE q.id=first_row.id) THEN
    RAISE EXCEPTION 'Approval cursor repeated its boundary row';
  END IF;
  PERFORM public.decide_booking_approval(org,cancellation,'approved','approved cancellation');
  IF NOT EXISTS (SELECT 1 FROM public.list_executable_booking_changes_v1(org) q WHERE q.approval_request_id=cancellation) THEN
    RAISE EXCEPTION 'Approved cancellation did not appear as executable';
  END IF;
  PERFORM pg_temp.check_rejection(format('SELECT public.execute_booking_cancellation_v2(%L,%L,%L,%L)',
    org,booking,current_setting('repair.confirmation'),'repair-execute'), '22023');
  PERFORM public.execute_booking_cancellation_v2(org,booking,cancellation,'repair-execute');
  PERFORM public.execute_booking_cancellation_v2(org,booking,cancellation,'repair-execute');
END;
$$;
RESET ROLE;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.property_occupancies WHERE booking_id=current_setting('repair.booking')::uuid) THEN
    RAISE EXCEPTION 'Cancellation did not release occupied nights';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE action='booking.cancelled' AND resource_id=current_setting('repair.booking')::uuid) <> 1 THEN
    RAISE EXCEPTION 'Cancellation replay duplicated audit evidence';
  END IF;
END;
$$;

-- A legacy media failure remains present without reactivating its channel.
INSERT INTO public.whatsapp_channels (
  id, organization_id, provider, external_channel_id, display_name, status, kill_switch, created_by_membership_id
)
SELECT 'df12b31c-8286-4041-8faf-a24e937399ee', m.organization_id, 'openwa', 'repair-archived-channel', 'Archived media', 'disabled', true, m.id
FROM public.organization_memberships m
WHERE m.organization_id = current_setting('repair.org')::uuid AND m.user_id = '11111111-1111-1111-1111-111111111111';
INSERT INTO public.whatsapp_conversations (id, organization_id, channel_id, external_conversation_key)
VALUES ('12f582a0-de30-4f5d-b664-4f0490acfd7c', current_setting('repair.org')::uuid,
  'df12b31c-8286-4041-8faf-a24e937399ee', 'repair-conversation');
INSERT INTO public.whatsapp_message_events (
  id, organization_id, conversation_id, event_key, direction, body_text, delivery_status, message_type, media_status, provider_media_id
) VALUES ('79d62689-5fc1-4ed2-8208-15ce7108da56',current_setting('repair.org')::uuid,'12f582a0-de30-4f5d-b664-4f0490acfd7c',
  'repair-inbound-image','inbound','Synthetic image','received','image','pending','repair-archived-image');
INSERT INTO public.outbox_events (organization_id,event_type,schema_version,dedupe_key,payload,state,last_error_code)
VALUES (current_setting('repair.org')::uuid,'whatsapp.media.store_requested',1,'repair-media',
  '{"message_id":"79d62689-5fc1-4ed2-8208-15ce7108da56"}','needs_review','unsupported_outbox_event');
SET LOCAL ROLE authenticated;
DO $$
DECLARE org uuid := current_setting('repair.org')::uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.list_whatsapp_conversations_ai_v1(org) c
    CROSS JOIN LATERAL jsonb_array_elements(c.recent_messages) m
    WHERE m->>'id' = '79d62689-5fc1-4ed2-8208-15ce7108da56' AND m->>'media_status' = 'needs_review'
  ) THEN RAISE EXCEPTION 'Legacy media still projects as pending'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.get_whatsapp_media_health_v1(org) h
    WHERE h.media_review_count = 1 AND h.oldest_media_review_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'Attachment health does not report review count'; END IF;
  IF (SELECT whatsapp_failure_count FROM public.get_system_health_v1(org)) <> 0 THEN
    RAISE EXCEPTION 'Attachment failure was counted as outbound';
  END IF;
  PERFORM pg_temp.check_rejection(
    'SELECT public.get_whatsapp_media_health_v1(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'')', '42501'
  );
END;
$$;
RESET ROLE;
ROLLBACK;
