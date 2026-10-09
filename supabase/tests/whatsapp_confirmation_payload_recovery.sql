-- Exercise the effective authenticated/AAL2 RPC on the phase-1 fixture.
-- All mutations are rolled back, so later proofs retain their original fixture.
BEGIN;
SELECT id::text AS amendment_conversation_id, property_owner_id::text AS amendment_owner_id,
  property_id::text AS amendment_property_id, confirmation_payload::text AS amendment_payload
FROM public.whatsapp_conversations
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND external_conversation_key = 'phase1-owner-confirm-thread' \gset
SELECT set_config('voya.test.amendment_conversation', :'amendment_conversation_id', true);
SELECT set_config('voya.test.amendment_owner', :'amendment_owner_id', true);
SELECT set_config('voya.test.amendment_property', :'amendment_property_id', true);
SELECT set_config('voya.test.amendment_payload', :'amendment_payload', true);
-- Simulate owner committed/property rejected. The property fixture has a
-- different key; the owner has the original key even if its response was lost.
UPDATE public.property_owners SET idempotency_key = 'amendment-owner'
WHERE id = :'amendment_owner_id'::uuid;
UPDATE public.whatsapp_conversations SET confirmation_status = 'partially_applied',
 confirmation_key = 'amendment', confirmation_token = 'aaaaaaaa-0000-0000-0000-000000009201', confirmation_claimed_at = timezone('utc', now()), confirmation_result = jsonb_build_object(
 'commandKeys', jsonb_build_object('owner', 'amendment-owner', 'property', 'amendment-property', 'ownership', 'amendment-ownership')),
 confirmation_payload = :'amendment_payload'::jsonb
WHERE id = :'amendment_conversation_id'::uuid;
SELECT set_config('voya.test.amendment_version', ai_state_version::text, true) FROM public.whatsapp_conversations WHERE id = :'amendment_conversation_id'::uuid;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claim.aal', 'aal2', true);
SAVEPOINT correction;
DO $$
DECLARE v_claim record; v_version integer; v_payload jsonb; v_token uuid; v_property_id uuid; v_period_id uuid;
BEGIN
 v_version := current_setting('voya.test.amendment_version')::integer;
 v_payload := jsonb_set(current_setting('voya.test.amendment_payload')::jsonb, '{property,code}', '"CORRECTED-CODE"');
 v_payload := jsonb_set(v_payload, '{owner,displayName}', '"must not replace committed owner"');
 SELECT * INTO v_claim FROM public.claim_whatsapp_property_confirmation_v1(
 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.amendment_conversation')::uuid,
 v_payload, v_version, 'new-amendment-key');
 v_token := v_claim.confirmation_token;
 IF v_claim.confirmation_payload #>> '{property,code}' <> 'CORRECTED-CODE' THEN
 RAISE EXCEPTION 'uncommitted property code must accept operator correction'; END IF;
 IF v_claim.confirmation_result ->> 'propertyOwnerId' <> current_setting('voya.test.amendment_owner') THEN
 RAISE EXCEPTION 'lost owner response must recover committed owner by original command key'; END IF;
 IF v_claim.confirmation_payload -> 'owner' <> current_setting('voya.test.amendment_payload')::jsonb -> 'owner' THEN
 RAISE EXCEPTION 'committed owner fields must remain frozen'; END IF;
 IF v_claim.confirmation_result #>> '{commandKeys,property}' <> 'amendment-property' THEN
 RAISE EXCEPTION 'pending command key must remain stable to fence late original writes'; END IF;
 -- A parallel click with the same key must never share the execution token.
 SELECT * INTO v_claim FROM public.claim_whatsapp_property_confirmation_v1(
 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.amendment_conversation')::uuid,
 v_payload, v_claim.conversation_version, 'amendment');
 IF v_claim.outcome <> 'in_progress' OR v_claim.confirmation_token IS NOT NULL THEN
 RAISE EXCEPTION 'live claim must not disclose reusable execution token'; END IF;
 v_property_id := public.create_property_v1(
 p_organization_id => 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
 p_code => (v_payload #>> '{property,code}')::text,
 p_name => (v_payload #>> '{property,name}')::text,
 p_timezone => (v_payload #>> '{property,timezone}')::text,
 p_address => (v_payload #>> '{property,address}')::text,
 p_city => (v_payload #>> '{property,city}')::text,
 p_unit_label => (v_payload #>> '{property,unitLabel}')::text,
 p_bedrooms => (v_payload #>> '{property,bedrooms}')::integer,
 p_max_guests => (v_payload #>> '{property,maxGuests}')::integer,
 p_operational_notes => (v_payload #>> '{property,operationalNotes}')::text,
 p_bathrooms => (v_payload #>> '{property,bathrooms}')::integer,
 p_area_sqm => (v_payload #>> '{property,areaSqm}')::numeric,
 p_floor => (v_payload #>> '{property,floor}')::text,
 p_furnished => (v_payload #>> '{property,furnished}')::boolean,
 p_district => (v_payload #>> '{property,district}')::text,
 p_rent_daily => (v_payload #>> '{property,rentDaily}')::boolean,
 p_rent_weekly => (v_payload #>> '{property,rentWeekly}')::boolean,
 p_rent_monthly => (v_payload #>> '{property,rentMonthly}')::boolean,
 p_daily_price => (v_payload #>> '{property,dailyPrice}')::numeric,
 p_weekly_price => (v_payload #>> '{property,weeklyPrice}')::numeric,
 p_monthly_price => (v_payload #>> '{property,monthlyPrice}')::numeric,
 p_currency => (v_payload #>> '{property,currency}')::text,
 p_minimum_stay_nights => (v_payload #>> '{property,minimumStayNights}')::integer,
 p_marketing_description => (v_payload #>> '{property,marketingDescription}')::text,
 p_amenities => ARRAY(SELECT jsonb_array_elements_text(v_payload #> '{property,amenities}')),
 p_idempotency_key => 'amendment-property');
 v_period_id := public.assign_property_owner_v1(
 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_property_id, current_setting('voya.test.amendment_owner')::uuid,
 '2026-08-27', '2099-12-31', true, 'amendment-ownership');
 IF NOT public.finalize_whatsapp_property_confirmation_v1(
 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.amendment_conversation')::uuid,
 v_token, current_setting('voya.test.amendment_owner')::uuid, v_property_id, 'confirmed',
 jsonb_build_object('propertyId', v_property_id, 'propertyOwnerId', current_setting('voya.test.amendment_owner'), 'ownershipPeriodId', v_period_id)) THEN
 RAISE EXCEPTION 'corrected pending command must complete confirmation'; END IF;
END;
$$;
ROLLBACK TO SAVEPOINT correction;
RESET ROLE;
-- Expired claims reconcile the original pending payload, even when a
-- corrected browser form is supplied. This fences still-running executors.
SAVEPOINT expired_pending;
UPDATE public.whatsapp_conversations SET confirmation_status = 'claimed',
 confirmation_claimed_at = timezone('utc', now()) - interval '31 minutes'
WHERE id = :'amendment_conversation_id'::uuid;
SET ROLE authenticated;
DO $$ DECLARE v_claim record; BEGIN
 SELECT * INTO v_claim FROM public.claim_whatsapp_property_confirmation_v1(
 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.amendment_conversation')::uuid,
 jsonb_set(current_setting('voya.test.amendment_payload')::jsonb, '{property,code}', '"unsafe-expired-amendment"'),
 current_setting('voya.test.amendment_version')::integer, 'expired-pending');
 IF v_claim.confirmation_payload <> current_setting('voya.test.amendment_payload')::jsonb THEN
 RAISE EXCEPTION 'expired pending payload must remain immutable'; END IF;
END; $$;
RESET ROLE;
ROLLBACK TO SAVEPOINT expired_pending;
-- Simulate a crash after all three inventory commands committed but before
-- their IDs reached the action. Expired claims must reconcile those keys.
UPDATE public.properties SET idempotency_key = 'amendment-property' WHERE id = :'amendment_property_id'::uuid;
UPDATE public.property_ownership_periods SET idempotency_key = 'amendment-ownership'
WHERE property_id = :'amendment_property_id'::uuid AND property_owner_id = :'amendment_owner_id'::uuid
 AND start_date = '2026-08-27' AND end_date = '2099-12-31';
UPDATE public.whatsapp_conversations SET confirmation_status = 'claimed',
 confirmation_claimed_at = timezone('utc', now()) - interval '31 minutes',
 confirmation_payload = :'amendment_payload'::jsonb,
 confirmation_result = jsonb_build_object('commandKeys', jsonb_build_object(
 'owner', 'amendment-owner', 'property', 'amendment-property', 'ownership', 'amendment-ownership'))
WHERE id = :'amendment_conversation_id'::uuid;
SELECT set_config('voya.test.amendment_version', ai_state_version::text, true),
 set_config('voya.test.amendment_old_token', confirmation_token::text, true)
FROM public.whatsapp_conversations WHERE id = :'amendment_conversation_id'::uuid;
SET ROLE authenticated;
DO $$
DECLARE v_claim record; v_payload jsonb := current_setting('voya.test.amendment_payload')::jsonb;
BEGIN
 BEGIN
 PERFORM public.claim_whatsapp_property_confirmation_v1(
 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.amendment_conversation')::uuid,
 v_payload, current_setting('voya.test.amendment_version')::integer - 1, 'stale-amendment');
 RAISE EXCEPTION 'stale recovery must fail'; EXCEPTION WHEN serialization_failure THEN NULL; END;
 v_payload := jsonb_set(jsonb_set(v_payload, '{property,code}', '"must-not-replace"'), '{ownershipStartDate}', '"2027-01-01"');
 SELECT * INTO v_claim FROM public.claim_whatsapp_property_confirmation_v1(
 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.amendment_conversation')::uuid,
 v_payload, current_setting('voya.test.amendment_version')::integer, 'expired-amendment');
 IF v_claim.confirmation_payload <> current_setting('voya.test.amendment_payload')::jsonb
 OR v_claim.confirmation_result ->> 'propertyId' <> current_setting('voya.test.amendment_property')
 OR v_claim.confirmation_result ->> 'ownershipPeriodId' IS NULL
 OR v_claim.confirmation_token::text = current_setting('voya.test.amendment_old_token') THEN
 RAISE EXCEPTION 'expired lost-response recovery must freeze committed fields and rotate token'; END IF;
 BEGIN
 PERFORM public.finalize_whatsapp_property_confirmation_v1(
 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.amendment_conversation')::uuid,
 current_setting('voya.test.amendment_old_token')::uuid, NULL, NULL, 'partially_applied', '{}'::jsonb);
 RAISE EXCEPTION 'old executor must not finalize rotated claim'; EXCEPTION WHEN serialization_failure THEN NULL; END;
 BEGIN
 PERFORM public.claim_whatsapp_property_confirmation_v1(
 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', current_setting('voya.test.amendment_conversation')::uuid,
 v_payload, v_claim.conversation_version, 'foreign-tenant');
 RAISE EXCEPTION 'tenant mismatch must fail';
 EXCEPTION WHEN insufficient_privilege OR foreign_key_violation THEN NULL; END;
END;
$$;
RESET ROLE;
-- A late original commit after an amendment must fail closed on every
-- supplied field (including nonidentity property fields).
UPDATE public.whatsapp_conversations SET confirmation_status = 'partially_applied',
 confirmation_payload = jsonb_set(confirmation_payload, '{property,city}', '"amended-city-not-committed"')
WHERE id = :'amendment_conversation_id'::uuid;
SELECT set_config('voya.test.amendment_version', ai_state_version::text, true) FROM public.whatsapp_conversations WHERE id = :'amendment_conversation_id'::uuid;
SET ROLE authenticated;
DO $$ BEGIN
 BEGIN
 PERFORM public.claim_whatsapp_property_confirmation_v1(
 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.amendment_conversation')::uuid,
 '{}'::jsonb, current_setting('voya.test.amendment_version')::integer, 'late-original-commit');
 RAISE EXCEPTION 'late original commit must not be reported with amended fields';
 EXCEPTION WHEN unique_violation THEN NULL; END;
END; $$;
RESET ROLE;
UPDATE public.whatsapp_conversations SET confirmation_payload = :'amendment_payload'::jsonb WHERE id = :'amendment_conversation_id'::uuid;
-- An archived key result is a review error, never permission to recreate it.
UPDATE public.properties SET status = 'archived', archived_at = timezone('utc', now()) WHERE id = :'amendment_property_id'::uuid;
UPDATE public.whatsapp_conversations SET confirmation_status = 'partially_applied' WHERE id = :'amendment_conversation_id'::uuid;
SELECT set_config('voya.test.amendment_version', ai_state_version::text, true) FROM public.whatsapp_conversations WHERE id = :'amendment_conversation_id'::uuid;
SET ROLE authenticated;
DO $$
BEGIN
 BEGIN
 PERFORM public.claim_whatsapp_property_confirmation_v1(
 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.amendment_conversation')::uuid,
 '{}'::jsonb, current_setting('voya.test.amendment_version')::integer, 'archived-amendment');
 RAISE EXCEPTION 'archived property recovery must fail'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
END;
$$;
RESET ROLE;
-- Creation normalizes email and text before storing. Historical accepted
-- payloads must compare using exactly those same command rules.
UPDATE public.properties SET status = 'active', archived_at = NULL WHERE id = :'amendment_property_id'::uuid;
SET ROLE authenticated;
SELECT public.create_property_owner_v1(
 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', ' Mixed Email Owner ', '', '',
 'Owner@Example.COM', 'email', '', 'mixed-email-owner')::text AS normalized_owner_id \gset
RESET ROLE;
UPDATE public.whatsapp_conversations SET confirmation_status = 'partially_applied',
 confirmation_payload = jsonb_set(:'amendment_payload'::jsonb, '{owner}',
 jsonb_build_object('displayName', ' Mixed Email Owner ', 'phone', '', 'whatsapp', '',
 'email', 'Owner@Example.COM', 'preferredContactMethod', 'email', 'notes', '')),
 confirmation_result = jsonb_build_object('commandKeys', jsonb_build_object(
 'owner', 'mixed-email-owner', 'property', 'amendment-property', 'ownership', 'unused-normalized-ownership'))
WHERE id = :'amendment_conversation_id'::uuid;
UPDATE public.whatsapp_conversations SET confirmation_payload = jsonb_set(
 confirmation_payload, '{property}', (confirmation_payload -> 'property') || jsonb_build_object(
 'code', ' ' || (confirmation_payload #>> '{property,code}') || ' ',
 'name', ' ' || (confirmation_payload #>> '{property,name}') || ' ',
 'timezone', ' ' || (confirmation_payload #>> '{property,timezone}') || ' ',
 'city', ' ' || (confirmation_payload #>> '{property,city}') || ' ',
 'floor', ' ' || (confirmation_payload #>> '{property,floor}') || ' ',
 'rentDaily', NULL, 'rentWeekly', NULL))
WHERE id = :'amendment_conversation_id'::uuid;
SELECT set_config('voya.test.amendment_version', ai_state_version::text, true),
 set_config('voya.test.normalized_owner', :'normalized_owner_id', true)
FROM public.whatsapp_conversations WHERE id = :'amendment_conversation_id'::uuid;
SET ROLE authenticated;
DO $$ DECLARE v_claim record; BEGIN
 SELECT * INTO v_claim FROM public.claim_whatsapp_property_confirmation_v1(
 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_setting('voya.test.amendment_conversation')::uuid,
 '{}'::jsonb, current_setting('voya.test.amendment_version')::integer, 'mixed-email-recovery');
 IF v_claim.confirmation_result ->> 'propertyOwnerId' <> current_setting('voya.test.normalized_owner') THEN
 RAISE EXCEPTION 'mixedcase accepted email must recover the original committed owner'; END IF;
END; $$;
RESET ROLE;
ROLLBACK;
