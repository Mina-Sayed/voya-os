-- Voya OS: tenant-scoped fleet and transport operations.
-- This migration records operational facts only. Pricing, payment, provider, and
-- driver compensation policies remain intentionally out of scope.

CREATE TABLE public.fleet_vehicles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 120),
  vehicle_type text NOT NULL CHECK (vehicle_type IN ('sedan', 'suv', 'van', 'bus', 'other')),
  registration_code text NOT NULL CHECK (char_length(btrim(registration_code)) BETWEEN 1 AND 40),
  passenger_capacity smallint NOT NULL CHECK (passenger_capacity BETWEEN 1 AND 80),
  status text NOT NULL DEFAULT 'available' CHECK (status IN ('available', 'maintenance', 'inactive')),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, registration_code)
);

CREATE TABLE public.fleet_drivers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 160),
  phone_e164 text CHECK (phone_e164 IS NULL OR phone_e164 ~ '^\+[1-9][0-9]{4,31}$'),
  status text NOT NULL DEFAULT 'available' CHECK (status IN ('available', 'off_duty', 'inactive')),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, id)
);

CREATE TABLE public.transport_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  request_type text NOT NULL CHECK (request_type IN ('airport_transfer', 'car_rental')),
  status text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested', 'assigned', 'in_progress', 'completed', 'cancelled')),
  guest_label text NOT NULL CHECK (char_length(btrim(guest_label)) BETWEEN 1 AND 160),
  pickup_location text NOT NULL CHECK (char_length(btrim(pickup_location)) BETWEEN 1 AND 240),
  dropoff_location text NOT NULL CHECK (char_length(btrim(dropoff_location)) BETWEEN 1 AND 240),
  pickup_at timestamptz NOT NULL,
  return_at timestamptz,
  passenger_count smallint NOT NULL DEFAULT 1 CHECK (passenger_count BETWEEN 1 AND 80),
  vehicle_id uuid,
  driver_id uuid,
  booking_id uuid,
  notes text CHECK (notes IS NULL OR char_length(btrim(notes)) BETWEEN 1 AND 2000),
  created_by_membership_id uuid NOT NULL,
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT transport_return_after_pickup CHECK (return_at IS NULL OR return_at > pickup_at),
  CONSTRAINT transport_vehicle_in_organization_fk FOREIGN KEY (organization_id, vehicle_id)
    REFERENCES public.fleet_vehicles(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT transport_driver_in_organization_fk FOREIGN KEY (organization_id, driver_id)
    REFERENCES public.fleet_drivers(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT transport_booking_in_organization_fk FOREIGN KEY (organization_id, booking_id)
    REFERENCES public.bookings(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT transport_creator_in_organization_fk FOREIGN KEY (organization_id, created_by_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT transport_idempotency_unique UNIQUE (organization_id, idempotency_key)
);

CREATE INDEX fleet_vehicles_queue_idx ON public.fleet_vehicles (organization_id, status, created_at DESC);
CREATE INDEX fleet_drivers_queue_idx ON public.fleet_drivers (organization_id, status, created_at DESC);
CREATE INDEX transport_requests_queue_idx ON public.transport_requests (organization_id, status, pickup_at, created_at DESC);
CREATE INDEX transport_requests_booking_idx ON public.transport_requests (organization_id, booking_id, created_at DESC);

CREATE TRIGGER fleet_vehicles_set_updated_at BEFORE UPDATE ON public.fleet_vehicles
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER fleet_drivers_set_updated_at BEFORE UPDATE ON public.fleet_drivers
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER transport_requests_set_updated_at BEFORE UPDATE ON public.transport_requests
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.fleet_vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fleet_vehicles FORCE ROW LEVEL SECURITY;
ALTER TABLE public.fleet_drivers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fleet_drivers FORCE ROW LEVEL SECURITY;
ALTER TABLE public.transport_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transport_requests FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.fleet_vehicles, public.fleet_drivers, public.transport_requests FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.create_fleet_vehicle(
  p_organization_id uuid,
  p_display_name text,
  p_vehicle_type text,
  p_registration_code text,
  p_passenger_capacity integer,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'fleet vehicle creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_display_name IS NULL OR char_length(btrim(p_display_name)) NOT BETWEEN 1 AND 120
    OR p_vehicle_type IS NULL OR p_vehicle_type NOT IN ('sedan', 'suv', 'van', 'bus', 'other')
    OR p_registration_code IS NULL OR char_length(btrim(p_registration_code)) NOT BETWEEN 1 AND 40
    OR p_passenger_capacity IS NULL OR p_passenger_capacity NOT BETWEEN 1 AND 80 THEN
    RAISE EXCEPTION 'vehicle input is invalid' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.fleet_vehicles (organization_id, display_name, vehicle_type, registration_code, passenger_capacity)
  VALUES (p_organization_id, btrim(p_display_name), p_vehicle_type, btrim(p_registration_code), p_passenger_capacity)
  RETURNING id INTO v_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'fleet.vehicle.created', 'fleet_vehicle', v_id, 'success', p_request_id,
    jsonb_build_object('vehicle_type', p_vehicle_type, 'passenger_capacity', p_passenger_capacity));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'fleet.vehicle.created', 1, 'fleet-vehicle:' || v_id::text, jsonb_build_object('vehicle_id', v_id));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_fleet_driver(
  p_organization_id uuid,
  p_display_name text,
  p_phone_e164 text DEFAULT NULL,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'fleet driver creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_display_name IS NULL OR char_length(btrim(p_display_name)) NOT BETWEEN 1 AND 160
    OR (p_phone_e164 IS NOT NULL AND p_phone_e164 !~ '^\+[1-9][0-9]{4,31}$') THEN
    RAISE EXCEPTION 'driver input is invalid' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.fleet_drivers (organization_id, display_name, phone_e164)
  VALUES (p_organization_id, btrim(p_display_name), NULLIF(btrim(p_phone_e164), ''))
  RETURNING id INTO v_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'fleet.driver.created', 'fleet_driver', v_id, 'success', p_request_id,
    jsonb_build_object('has_phone', p_phone_e164 IS NOT NULL));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'fleet.driver.created', 1, 'fleet-driver:' || v_id::text, jsonb_build_object('driver_id', v_id));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_fleet_vehicles(p_organization_id uuid)
RETURNS TABLE (id uuid, display_name text, vehicle_type text, registration_code text, passenger_capacity smallint, status text, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations')) THEN
    RAISE EXCEPTION 'fleet vehicle read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT vehicle.id, vehicle.display_name, vehicle.vehicle_type, vehicle.registration_code, vehicle.passenger_capacity, vehicle.status, vehicle.created_at
  FROM public.fleet_vehicles AS vehicle WHERE vehicle.organization_id = p_organization_id ORDER BY vehicle.status, vehicle.created_at DESC, vehicle.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_fleet_drivers(p_organization_id uuid)
RETURNS TABLE (id uuid, display_name text, phone_e164 text, status text, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations')) THEN
    RAISE EXCEPTION 'fleet driver read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT driver.id, driver.display_name, driver.phone_e164, driver.status, driver.created_at
  FROM public.fleet_drivers AS driver WHERE driver.organization_id = p_organization_id ORDER BY driver.status, driver.created_at DESC, driver.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_transport_request(
  p_organization_id uuid,
  p_request_type text,
  p_guest_label text,
  p_pickup_location text,
  p_dropoff_location text,
  p_pickup_at timestamptz,
  p_passenger_count integer DEFAULT 1,
  p_return_at timestamptz DEFAULT NULL,
  p_booking_id uuid DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_existing public.transport_requests%ROWTYPE; v_id uuid;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'transport request creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_request_type IS NULL OR p_request_type NOT IN ('airport_transfer', 'car_rental')
    OR p_guest_label IS NULL OR char_length(btrim(p_guest_label)) NOT BETWEEN 1 AND 160
    OR p_pickup_location IS NULL OR char_length(btrim(p_pickup_location)) NOT BETWEEN 1 AND 240
    OR p_dropoff_location IS NULL OR char_length(btrim(p_dropoff_location)) NOT BETWEEN 1 AND 240
    OR p_pickup_at IS NULL OR p_passenger_count IS NULL OR p_passenger_count NOT BETWEEN 1 AND 80
    OR (p_return_at IS NOT NULL AND p_return_at <= p_pickup_at)
    OR (p_notes IS NOT NULL AND char_length(btrim(p_notes)) NOT BETWEEN 1 AND 2000)
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'transport request input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_booking_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id) THEN
    RAISE EXCEPTION 'transport booking is invalid' USING ERRCODE = '23503';
  END IF;
  SELECT request.* INTO v_existing FROM public.transport_requests AS request
  WHERE request.organization_id = p_organization_id AND request.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.request_type = p_request_type AND v_existing.guest_label = btrim(p_guest_label)
      AND v_existing.pickup_location = btrim(p_pickup_location) AND v_existing.dropoff_location = btrim(p_dropoff_location)
      AND v_existing.pickup_at = p_pickup_at AND v_existing.return_at IS NOT DISTINCT FROM p_return_at
      AND v_existing.passenger_count = p_passenger_count AND v_existing.booking_id IS NOT DISTINCT FROM p_booking_id
      AND v_existing.notes IS NOT DISTINCT FROM NULLIF(btrim(p_notes), '') THEN RETURN v_existing.id; END IF;
    RAISE EXCEPTION 'transport idempotency key belongs to a different request' USING ERRCODE = '23505';
  END IF;
  INSERT INTO public.transport_requests (organization_id, request_type, guest_label, pickup_location, dropoff_location, pickup_at, return_at, passenger_count, booking_id, notes, created_by_membership_id, idempotency_key)
  VALUES (p_organization_id, p_request_type, btrim(p_guest_label), btrim(p_pickup_location), btrim(p_dropoff_location), p_pickup_at, p_return_at, p_passenger_count, p_booking_id, NULLIF(btrim(p_notes), ''), v_actor, btrim(p_idempotency_key))
  RETURNING id INTO v_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'transport.request.created', 'transport_request', v_id, 'success', p_request_id, jsonb_build_object('request_type', p_request_type, 'passenger_count', p_passenger_count));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'transport.request.created', 1, 'transport-request:' || v_id::text, jsonb_build_object('transport_request_id', v_id));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_transport_requests(p_organization_id uuid, p_limit integer DEFAULT 100)
RETURNS TABLE (id uuid, request_type text, status text, guest_label text, pickup_location text, dropoff_location text, pickup_at timestamptz, return_at timestamptz, passenger_count smallint, vehicle_id uuid, vehicle_name text, driver_id uuid, driver_name text, booking_id uuid, notes text, created_at timestamptz, updated_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN RAISE EXCEPTION 'transport read is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'transport limit is invalid' USING ERRCODE = '22023'; END IF;
  RETURN QUERY SELECT request.id, request.request_type, request.status, request.guest_label, request.pickup_location, request.dropoff_location, request.pickup_at, request.return_at, request.passenger_count, request.vehicle_id, vehicle.display_name, request.driver_id, driver.display_name, request.booking_id, request.notes, request.created_at, request.updated_at
  FROM public.transport_requests AS request
  LEFT JOIN public.fleet_vehicles AS vehicle ON vehicle.organization_id = request.organization_id AND vehicle.id = request.vehicle_id
  LEFT JOIN public.fleet_drivers AS driver ON driver.organization_id = request.organization_id AND driver.id = request.driver_id
  WHERE request.organization_id = p_organization_id
    AND (v_role IN ('owner', 'manager', 'operations') OR request.created_by_membership_id = v_actor)
  ORDER BY (request.status IN ('completed', 'cancelled')), request.pickup_at, request.created_at DESC, request.id DESC LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.assign_transport_request(
  p_organization_id uuid,
  p_request_id uuid,
  p_vehicle_id uuid DEFAULT NULL,
  p_driver_id uuid DEFAULT NULL,
  p_request_idempotency uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_old public.transport_requests%ROWTYPE;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'transport assignment is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT request.* INTO v_old FROM public.transport_requests AS request WHERE request.organization_id = p_organization_id AND request.id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'transport request is invalid' USING ERRCODE = '23503'; END IF;
  IF v_old.status IN ('completed', 'cancelled') THEN RAISE EXCEPTION 'transport request cannot be assigned in its current state' USING ERRCODE = '22023'; END IF;
  IF p_vehicle_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.fleet_vehicles AS vehicle WHERE vehicle.organization_id = p_organization_id AND vehicle.id = p_vehicle_id AND vehicle.status = 'available') THEN RAISE EXCEPTION 'transport vehicle is not available' USING ERRCODE = '23503'; END IF;
  IF p_driver_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.fleet_drivers AS driver WHERE driver.organization_id = p_organization_id AND driver.id = p_driver_id AND driver.status = 'available') THEN RAISE EXCEPTION 'transport driver is not available' USING ERRCODE = '23503'; END IF;
  UPDATE public.transport_requests SET vehicle_id = p_vehicle_id, driver_id = p_driver_id, status = CASE WHEN p_vehicle_id IS NULL AND p_driver_id IS NULL THEN 'requested' ELSE 'assigned' END WHERE id = p_request_id AND organization_id = p_organization_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, before_delta, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'transport.request.assigned', 'transport_request', p_request_id, 'success', p_request_idempotency, jsonb_build_object('vehicle_id', v_old.vehicle_id, 'driver_id', v_old.driver_id), jsonb_build_object('vehicle_id', p_vehicle_id, 'driver_id', p_driver_id));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'transport.request.assigned', 1, 'transport-assignment:' || p_request_id::text || ':' || coalesce(p_vehicle_id::text, 'none') || ':' || coalesce(p_driver_id::text, 'none'), jsonb_build_object('transport_request_id', p_request_id));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_transport_request_status(p_organization_id uuid, p_request_id uuid, p_status text, p_request_idempotency uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_old text;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'transport status update is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_status IS NULL OR p_status NOT IN ('requested', 'assigned', 'in_progress', 'completed', 'cancelled') THEN RAISE EXCEPTION 'transport status is invalid' USING ERRCODE = '22023'; END IF;
  SELECT request.status INTO v_old FROM public.transport_requests AS request WHERE request.organization_id = p_organization_id AND request.id = p_request_id FOR UPDATE;
  IF v_old IS NULL THEN RAISE EXCEPTION 'transport request is invalid' USING ERRCODE = '23503'; END IF;
  UPDATE public.transport_requests SET status = p_status WHERE id = p_request_id AND organization_id = p_organization_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, before_delta, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'transport.request.status_changed', 'transport_request', p_request_id, 'success', p_request_idempotency, jsonb_build_object('status', v_old), jsonb_build_object('status', p_status));
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.create_fleet_vehicle(uuid, text, text, text, integer, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_fleet_driver(uuid, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_fleet_vehicles(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_fleet_drivers(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_transport_request(uuid, text, text, text, text, timestamptz, integer, timestamptz, uuid, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_transport_requests(uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assign_transport_request(uuid, uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_transport_request_status(uuid, uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_fleet_vehicle(uuid, text, text, text, integer, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_fleet_driver(uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fleet_vehicles(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fleet_drivers(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_transport_request(uuid, text, text, text, text, timestamptz, integer, timestamptz, uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_transport_requests(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assign_transport_request(uuid, uuid, uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_transport_request_status(uuid, uuid, text, uuid) TO authenticated;
