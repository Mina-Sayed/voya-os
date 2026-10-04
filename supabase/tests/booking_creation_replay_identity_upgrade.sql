-- Upgrade evidence: historical mutable rows recover only trusted complete creation facts.
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id) VALUES('55555555-5555-5555-5555-555555555555') ON CONFLICT DO NOTHING;
INSERT INTO public.profiles(id, display_name) VALUES('55555555-5555-5555-5555-555555555555','Upgrade manager') ON CONFLICT DO NOTHING;
INSERT INTO public.organization_memberships(organization_id,user_id,role,status) VALUES('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','55555555-5555-5555-5555-555555555555','manager','active') ON CONFLICT (organization_id,user_id) DO UPDATE SET role='manager',status='active';
-- Recreate the pre-migration table boundary inside a rolled-back transaction.
DROP TRIGGER IF EXISTS bookings_preserve_creation_identity ON public.bookings;
ALTER TABLE public.bookings DROP COLUMN IF EXISTS creation_payload_hash;
INSERT INTO public.bookings(id, organization_id, property_id, client_id, status, check_in, check_out, agreed_total_amount_minor, currency, commercial_completion_status, idempotency_key)
VALUES
('aaaaaaaa-0000-0000-0000-00000000c501','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002','draft','2098-04-04','2098-04-06',20000,'EGP','complete','r05-historical-original'),
('aaaaaaaa-0000-0000-0000-00000000c502','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002','draft','2098-05-04','2098-05-06',20000,'EGP','complete','r05-historical-ambiguous'),
('aaaaaaaa-0000-0000-0000-00000000c503','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002','draft','2098-06-04','2098-06-06',20000,'EGP','complete','r05-historical-missing');
INSERT INTO public.audit_events(organization_id, actor_type, action, resource_type, resource_id, outcome, after_delta)
SELECT 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','system','booking.commercial_draft_created','booking', id, 'success',
jsonb_build_object('property_id', property_id,'client_id',client_id,'check_in',DATE '2098-04-01','check_out',DATE '2098-04-03','agreed_total_amount_minor',10000,'currency','EGP')
FROM public.bookings WHERE id IN ('aaaaaaaa-0000-0000-0000-00000000c501','aaaaaaaa-0000-0000-0000-00000000c502');
-- Multiple contradictory creation events are ambiguous: never copy current facts.
INSERT INTO public.audit_events(organization_id, actor_type, action, resource_type, resource_id, outcome, after_delta)
VALUES('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','system','booking.commercial_draft_created','booking','aaaaaaaa-0000-0000-0000-00000000c502','success',jsonb_build_object('property_id','aaaaaaaa-0000-0000-0000-000000000001','client_id','aaaaaaaa-0000-0000-0000-000000000002','check_in','2098-05-04','check_out','2098-05-06','agreed_total_amount_minor',20000,'currency','EGP'));
-- Conflicting command provenance must not convert an ambiguous commercial
-- creation into a legacy key that can be released.
INSERT INTO public.audit_events(organization_id,actor_type,action,resource_type,resource_id,outcome,after_delta)
VALUES('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','system','booking.draft_created','booking','aaaaaaaa-0000-0000-0000-00000000c502','success','{}');
-- Simulate the already-applied old R04 definition. A forward migration must repair it.
DO $$ DECLARE definition text; BEGIN
SELECT pg_get_functiondef('public.confirm_commercial_booking(uuid,uuid,text,uuid)'::regprocedure) INTO definition;
definition := replace(definition, 'v_booking.status IN (''confirmed'', ''checked_in'', ''checked_out'', ''completed'')', 'v_booking.status IN (''confirmed'', ''checked_in'', ''checked_out'', ''cancelled'', ''completed'')');
EXECUTE definition;
END $$;
\ir ../migrations/20261004010200_booking_creation_replay_identity.sql
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',true);
SELECT set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@example.test","role":"authenticated","aal":"aal2"}',true);
DO $$ DECLARE key text; BEGIN
IF public.create_commercial_booking_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002','2098-04-01','2098-04-03','10000','EGP','r05-historical-original') <> 'aaaaaaaa-0000-0000-0000-00000000c501'::uuid THEN
RAISE EXCEPTION 'backfilled original creation payload replay failed'; END IF;
FOREACH key IN ARRAY ARRAY['r05-historical-ambiguous','r05-historical-missing'] LOOP
BEGIN
PERFORM public.create_commercial_booking_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002','2098-05-04','2098-05-06','20000','EGP',key);
RAISE EXCEPTION 'unverifiable historical creation payload accepted: %',key;
EXCEPTION WHEN unique_violation THEN NULL; END;
END LOOP;
END $$;
SELECT public.cancel_booking_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-00000000c501','upgrade test','r05-upgrade-cancel');
DO $$ BEGIN
BEGIN
PERFORM public.confirm_commercial_booking('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-00000000c501','r05-upgrade-never-confirmed');
RAISE EXCEPTION 'forward migration left old cancelled-draft confirmation bug active';
EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
END $$;
-- The exposed legacy confirm command must preserve unknown commercial
-- creation keys too; NULL identity must never make a key reusable.
SELECT public.request_commercial_booking_approval('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-00000000c502','r05-ambiguous-approval') AS ambiguous_aid \gset
SELECT public.request_commercial_booking_approval('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-00000000c503','r05-missing-approval') AS missing_aid \gset
SELECT set_config('request.jwt.claim.sub','55555555-5555-5555-5555-555555555555',true);
SELECT set_config('request.jwt.claims','{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated","aal":"aal2"}',true);
SELECT public.decide_booking_approval('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',:'ambiguous_aid','approved','upgrade unknown identity');
SELECT public.decide_booking_approval('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',:'missing_aid','approved','upgrade unknown identity');
SELECT public.confirm_booking('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-00000000c502','r05-ambiguous-confirm');
SELECT public.confirm_booking('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-00000000c503','r05-missing-confirm');
RESET ROLE;
DO $$ BEGIN
IF (SELECT idempotency_key FROM public.bookings WHERE id='aaaaaaaa-0000-0000-0000-00000000c502') IS DISTINCT FROM 'r05-historical-ambiguous'
 OR (SELECT idempotency_key FROM public.bookings WHERE id='aaaaaaaa-0000-0000-0000-00000000c503') IS DISTINCT FROM 'r05-historical-missing' THEN
RAISE EXCEPTION 'legacy confirmation released an unverifiable commercial creation key'; END IF;
END $$;
RESET ROLE;
DO $$ BEGIN
IF EXISTS (SELECT 1 FROM public.bookings WHERE id IN ('aaaaaaaa-0000-0000-0000-00000000c502','aaaaaaaa-0000-0000-0000-00000000c503') AND creation_payload_hash IS NOT NULL) THEN
RAISE EXCEPTION 'ambiguous or missing historical creation identity fabricated'; END IF;
END $$;
ROLLBACK;
SELECT 'booking creation identity upgrade tests passed' AS result;
