-- Representative, tenant-consistent rows that exist before the production
-- security remediation migration is applied. The database harness discards
-- this database state after proving the forward upgrade.
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_actor uuid := (
    SELECT id FROM public.organization_memberships
    WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND user_id = '11111111-1111-1111-1111-111111111111'
  );
BEGIN
  INSERT INTO public.leads (
    id, organization_id, title, source, status,
    assigned_membership_id, idempotency_key
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000901',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'Upgrade fixture lead', 'upgrade_test', 'new', v_actor,
    'upgrade-fixture-lead'
  );

  INSERT INTO public.crm_contact_methods (
    id, organization_id, lead_id, client_id, kind, normalized_value,
    display_value, idempotency_key, created_by_membership_id
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000902',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000901',
    'aaaaaaaa-0000-0000-0000-000000000002',
    'whatsapp', '+201000000902', '+20 100 000 0902',
    'upgrade-fixture-contact', v_actor
  );

  INSERT INTO public.crm_consent_events (
    id, organization_id, contact_method_id, consent_scope, status, source,
    created_by_membership_id
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000903',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000902',
    'service', 'granted', 'upgrade_test', v_actor
  );

  INSERT INTO public.whatsapp_channels (
    id, organization_id, provider, external_channel_id, display_name,
    created_by_membership_id
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000904',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'upgrade_test', 'upgrade-fixture-channel', 'Upgrade fixture channel',
    v_actor
  );

  INSERT INTO public.whatsapp_conversations (
    id, organization_id, channel_id, contact_method_id, lead_id, client_id,
    external_conversation_key, assigned_membership_id
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000905',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000904',
    'aaaaaaaa-0000-0000-0000-000000000902',
    'aaaaaaaa-0000-0000-0000-000000000901',
    'aaaaaaaa-0000-0000-0000-000000000002',
    'upgrade-fixture-conversation', v_actor
  );

  INSERT INTO public.whatsapp_message_events (
    id, organization_id, conversation_id, event_key, direction, body_text,
    delivery_status, created_by_membership_id
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000906',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000905',
    'upgrade-fixture-message', 'inbound', 'Upgrade fixture message',
    'received', v_actor
  );

  INSERT INTO public.whatsapp_internal_notes (
    id, organization_id, conversation_id, note_text, created_by_membership_id
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000907',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000905',
    'Upgrade fixture note', v_actor
  );

  INSERT INTO public.operations_tasks (
    id, organization_id, task_type, title, booking_id,
    assigned_membership_id, created_by_membership_id, idempotency_key
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000908',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'upgrade_test', 'Upgrade fixture task',
    'aaaaaaaa-0000-0000-0000-000000000003',
    v_actor, v_actor, 'upgrade-fixture-task'
  );

  INSERT INTO public.fleet_vehicles (
    id, organization_id, display_name, vehicle_type, registration_code,
    passenger_capacity
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000909',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'Upgrade fixture vehicle', 'van', 'EG-UPGRADE-909', 8
  );
  INSERT INTO public.fleet_drivers (
    id, organization_id, display_name, phone_e164
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000910',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'Upgrade fixture driver', '+201000000910'
  );
  INSERT INTO public.transport_requests (
    id, organization_id, request_type, status, guest_label,
    pickup_location, dropoff_location, pickup_at, return_at, passenger_count,
    vehicle_id, driver_id, booking_id, created_by_membership_id, idempotency_key
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000911',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'car_rental', 'assigned', 'Upgrade fixture guest', 'A', 'B',
    '2050-01-01 10:00:00+00', '2050-01-01 14:00:00+00', 2,
    'aaaaaaaa-0000-0000-0000-000000000909',
    'aaaaaaaa-0000-0000-0000-000000000910',
    'aaaaaaaa-0000-0000-0000-000000000003',
    v_actor, 'upgrade-fixture-transport'
  );

  INSERT INTO public.auth_rate_limit_buckets (
    key_hash, scope, window_started_at, attempt_count
  ) VALUES (repeat('9', 64), 'magic_link', clock_timestamp(), 2);

  INSERT INTO public.auth_rate_limit_buckets (
    key_hash, scope, window_started_at, attempt_count
  ) VALUES (repeat('8', 64), 'password_sign_in', clock_timestamp(), 3);
END;
$$;
