\set ON_ERROR_STOP on
DO $$ BEGIN
IF has_function_privilege('anon','public.create_commercial_booking_draft(uuid,uuid,uuid,date,date,text,text,text,uuid)','EXECUTE')
 OR has_function_privilege('authenticated','public.cancel_booking_draft_without_workspace_aal2(uuid,uuid,text,text,uuid)','EXECUTE')
 OR has_function_privilege('authenticated','public.execute_booking_cancellation_without_workspace_aal2(uuid,uuid,text,uuid)','EXECUTE') THEN
RAISE EXCEPTION 'booking replay migration exposed private mutation primitives'; END IF;
END $$;
BEGIN;
INSERT INTO public.organizations(id,name,slug,timezone,default_currency,status) VALUES ('dddddddd-dddd-4ddd-8ddd-ddddddddda01','DB review amend','db-review-amend-proof','Africa/Cairo','EGP','active');
INSERT INTO public.organization_memberships(organization_id,user_id,role,status) VALUES ('dddddddd-dddd-4ddd-8ddd-ddddddddda01','11111111-1111-1111-1111-111111111111','owner','active'),('dddddddd-dddd-4ddd-8ddd-ddddddddda01','22222222-2222-2222-2222-222222222222','manager','active');
INSERT INTO public.properties(id,organization_id,code,name,timezone) VALUES('dddddddd-dddd-4ddd-8ddd-ddddddddda03','dddddddd-dddd-4ddd-8ddd-ddddddddda01','DB-AMEND','DB review unit','Africa/Cairo');
INSERT INTO public.clients(id,organization_id,display_name) VALUES('dddddddd-dddd-4ddd-8ddd-ddddddddda04','dddddddd-dddd-4ddd-8ddd-ddddddddda01','DB review client');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',true);
SELECT set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal2"}',true);
SELECT public.create_commercial_booking_draft('dddddddd-dddd-4ddd-8ddd-ddddddddda01','dddddddd-dddd-4ddd-8ddd-ddddddddda03','dddddddd-dddd-4ddd-8ddd-ddddddddda04','2098-02-01','2098-02-03','10000','EGP','amend-proof-create') AS bid \gset
SELECT set_config('review.booking_id',:'bid',true);
SELECT public.request_commercial_booking_approval('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'bid','amend-proof-approval') AS aid \gset
SELECT set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',true);
SELECT set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","email":"checker@example.test","role":"authenticated","aal":"aal2"}',true);
SELECT public.decide_booking_approval('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'aid','approved','review proof');
SELECT public.confirm_commercial_booking('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'bid','amend-proof-confirm');
SELECT set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',true);
SELECT set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal2"}',true);
SELECT public.request_booking_amendment('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'bid','dddddddd-dddd-4ddd-8ddd-ddddddddda03','dddddddd-dddd-4ddd-8ddd-ddddddddda04','2098-02-04','2098-02-06','20000','EGP','review amendment','amend-proof-request') AS mid \gset
SELECT set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',true);
SELECT set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","email":"checker@example.test","role":"authenticated","aal":"aal2"}',true);
SELECT public.decide_booking_approval('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'mid','approved','review proof');
SELECT public.execute_booking_amendment('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'bid',:'mid'::uuid,'amend-proof-execute');
DO $$ BEGIN
IF public.create_commercial_booking_draft('dddddddd-dddd-4ddd-8ddd-ddddddddda01','dddddddd-dddd-4ddd-8ddd-ddddddddda03','dddddddd-dddd-4ddd-8ddd-ddddddddda04','2098-02-01','2098-02-03','10000','EGP','amend-proof-create') <> current_setting('review.booking_id')::uuid THEN
RAISE EXCEPTION 'original creation replay returned a different booking after amendment'; END IF;
BEGIN
PERFORM public.create_commercial_booking_draft('dddddddd-dddd-4ddd-8ddd-ddddddddda01','dddddddd-dddd-4ddd-8ddd-ddddddddda03','dddddddd-dddd-4ddd-8ddd-ddddddddda04','2098-02-04','2098-02-06','20000','EGP','amend-proof-create');
RAISE EXCEPTION 'amended payload accepted under original creation key';
EXCEPTION WHEN unique_violation THEN NULL; END;
END $$;
SELECT set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',true);
SELECT set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal2"}',true);
SELECT public.request_booking_cancellation('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'bid','test cancellation','r05-cancel-request') AS cancel_aid \gset
SELECT set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',true);
SELECT set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","email":"checker@example.test","role":"authenticated","aal":"aal2"}',true);
SELECT public.decide_booking_approval('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'cancel_aid','approved','test cancellation');
SELECT public.execute_booking_cancellation('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'bid','r05-cancel-execute');
SELECT public.confirm_commercial_booking('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'bid','amend-proof-confirm');
DO $$ BEGIN
IF public.create_commercial_booking_draft('dddddddd-dddd-4ddd-8ddd-ddddddddda01','dddddddd-dddd-4ddd-8ddd-ddddddddda03','dddddddd-dddd-4ddd-8ddd-ddddddddda04','2098-02-01','2098-02-03','10000','EGP','amend-proof-create') <> current_setting('review.booking_id')::uuid THEN
RAISE EXCEPTION 'original creation replay returned a different booking after cancellation'; END IF;
END $$;
SELECT public.create_commercial_booking_draft('dddddddd-dddd-4ddd-8ddd-ddddddddda01','dddddddd-dddd-4ddd-8ddd-ddddddddda03','dddddddd-dddd-4ddd-8ddd-ddddddddda04','2098-03-01','2098-03-03','10000','EGP','r05-draft-cancel-create') AS draft_bid \gset
SELECT set_config('review.draft_booking_id',:'draft_bid',true);
SELECT public.cancel_booking_draft('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'draft_bid','test cancellation','r05-draft-cancel');
DO $$ BEGIN
IF public.create_commercial_booking_draft('dddddddd-dddd-4ddd-8ddd-ddddddddda01','dddddddd-dddd-4ddd-8ddd-ddddddddda03','dddddddd-dddd-4ddd-8ddd-ddddddddda04','2098-03-01','2098-03-03','10000','EGP','r05-draft-cancel-create') <> current_setting('review.draft_booking_id')::uuid THEN
RAISE EXCEPTION 'creation replay returned a different booking after draft cancellation'; END IF;
BEGIN
PERFORM public.confirm_commercial_booking('dddddddd-dddd-4ddd-8ddd-ddddddddda01',current_setting('review.draft_booking_id')::uuid,'r05-draft-never-confirmed');
RAISE EXCEPTION 'fresh confirmation accepted for cancelled draft';
EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
END $$;
-- Legacy confirmation is still an exposed guarded command and must also keep
-- a complete commercial booking's original creation key.
SELECT set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',true);
SELECT set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal2"}',true);
SELECT public.create_commercial_booking_draft('dddddddd-dddd-4ddd-8ddd-ddddddddda01','dddddddd-dddd-4ddd-8ddd-ddddddddda03','dddddddd-dddd-4ddd-8ddd-ddddddddda04','2098-07-01','2098-07-03','10000','EGP','r05-legacy-confirm-create') AS legacy_bid \gset
SELECT set_config('review.legacy_booking_id',:'legacy_bid',true);
SELECT public.request_commercial_booking_approval('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'legacy_bid','r05-legacy-approval') AS legacy_aid \gset
SELECT set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',true);
SELECT set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","email":"checker@example.test","role":"authenticated","aal":"aal2"}',true);
SELECT public.decide_booking_approval('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'legacy_aid','approved','legacy command test');
SELECT public.confirm_booking('dddddddd-dddd-4ddd-8ddd-ddddddddda01',:'legacy_bid','r05-legacy-confirm');
DO $$ BEGIN
IF public.create_commercial_booking_draft('dddddddd-dddd-4ddd-8ddd-ddddddddda01','dddddddd-dddd-4ddd-8ddd-ddddddddda03','dddddddd-dddd-4ddd-8ddd-ddddddddda04','2098-07-01','2098-07-03','10000','EGP','r05-legacy-confirm-create') <> current_setting('review.legacy_booking_id')::uuid THEN
RAISE EXCEPTION 'creation replay returned a different booking after legacy confirmation'; END IF;
END $$;
-- Cancellation must retain its database MFA wrapper.
SELECT set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","email":"checker@example.test","role":"authenticated","aal":"aal1"}',true);
DO $$ BEGIN
BEGIN
PERFORM public.cancel_booking_draft('dddddddd-dddd-4ddd-8ddd-ddddddddda01',current_setting('review.draft_booking_id')::uuid,'aal1 denied','r05-aal1-denied');
RAISE EXCEPTION 'draft cancellation lost its AAL2 gate';
EXCEPTION WHEN insufficient_privilege THEN NULL; END;
BEGIN
PERFORM public.execute_booking_cancellation('dddddddd-dddd-4ddd-8ddd-ddddddddda01',current_setting('review.booking_id')::uuid,'r05-aal1-execute-denied');
RAISE EXCEPTION 'approved cancellation lost its AAL2 gate';
EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
DO $$ BEGIN
BEGIN
UPDATE public.bookings SET creation_payload_hash=repeat('0',64) WHERE id=current_setting('review.booking_id')::uuid;
RAISE EXCEPTION 'persisted booking creation identity changed';
EXCEPTION WHEN check_violation THEN NULL; END;
IF (SELECT count(*) FROM public.audit_events WHERE organization_id='dddddddd-dddd-4ddd-8ddd-ddddddddda01' AND action='booking.commercial_draft_created') <> 3 THEN
RAISE EXCEPTION 'creation replays duplicated audit events'; END IF;
IF EXISTS (SELECT 1 FROM public.booking_v1_command_idempotency WHERE organization_id='dddddddd-dddd-4ddd-8ddd-ddddddddda01' AND idempotency_key='r05-draft-never-confirmed') THEN
RAISE EXCEPTION 'rejected confirmation persisted a key'; END IF;
END $$;
ROLLBACK;
SELECT 'immutable booking creation replay and cancellation tests passed' AS result;
