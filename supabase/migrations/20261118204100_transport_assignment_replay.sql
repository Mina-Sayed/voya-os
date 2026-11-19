-- Persist request identity even if an accepted assignment made no change.
CREATE TABLE public.transport_assignment_requests (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  request_key uuid NOT NULL,
  request_id uuid NOT NULL,
  vehicle_id uuid,
  driver_id uuid,
  PRIMARY KEY (organization_id, request_key)
);
ALTER TABLE public.transport_assignment_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transport_assignment_requests FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.transport_assignment_requests FROM PUBLIC, anon, authenticated, service_role;

-- Prior mutations carried the key and requested resources in immutable audit evidence.
INSERT INTO public.transport_assignment_requests (organization_id, request_key, request_id, vehicle_id, driver_id)
SELECT DISTINCT ON (organization_id, request_id)
  organization_id, request_id, resource_id,
  (after_delta->>'vehicle_id')::uuid, (after_delta->>'driver_id')::uuid
FROM public.audit_events
WHERE action = 'transport.request.assigned' AND resource_type = 'transport_request'
  AND outcome = 'success' AND request_id IS NOT NULL AND resource_id IS NOT NULL
ORDER BY organization_id, request_id, created_at, id;
CREATE OR REPLACE FUNCTION public.assign_transport_request_without_workspace_aal2(
  p_organization_id uuid,
  p_request_id uuid,
  p_vehicle_id uuid DEFAULT NULL,
  p_driver_id uuid DEFAULT NULL,
  p_request_idempotency uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_old public.transport_requests%ROWTYPE;
  v_new_status text;
  v_assignment_event_id uuid;
  v_bound public.transport_assignment_requests%ROWTYPE;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'transport assignment is not permitted' USING ERRCODE = '42501';
  END IF;

  IF p_request_idempotency IS NOT NULL THEN
    INSERT INTO public.transport_assignment_requests (organization_id, request_key, request_id, vehicle_id, driver_id)
    VALUES (p_organization_id, p_request_idempotency, p_request_id, p_vehicle_id, p_driver_id)
    ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN
      SELECT bound.* INTO STRICT v_bound
      FROM public.transport_assignment_requests AS bound
      WHERE bound.organization_id = p_organization_id AND bound.request_key = p_request_idempotency;
      IF (v_bound.request_id, v_bound.vehicle_id, v_bound.driver_id)
         IS DISTINCT FROM (p_request_id, p_vehicle_id, p_driver_id) THEN
        RAISE EXCEPTION 'transport assignment key belongs to a different request' USING ERRCODE = '23505';
      END IF;
      RETURN true;
    END IF;
  END IF;

  SELECT request.* INTO v_old
  FROM public.transport_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transport request is invalid' USING ERRCODE = '23503';
  END IF;
  IF v_old.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'transport request cannot be assigned in its current state' USING ERRCODE = '22023';
  END IF;
  IF v_old.status = 'in_progress'
    AND p_vehicle_id IS NULL
    AND p_driver_id IS NULL THEN
    RAISE EXCEPTION 'in-progress transport cannot release every assigned resource' USING ERRCODE = '22023';
  END IF;
  IF p_vehicle_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.fleet_vehicles AS vehicle
    WHERE vehicle.organization_id = p_organization_id
      AND vehicle.id = p_vehicle_id
      AND vehicle.status = 'available'
  ) THEN
    RAISE EXCEPTION 'transport vehicle is not available' USING ERRCODE = '23503';
  END IF;
  IF p_vehicle_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.fleet_vehicles AS vehicle
    WHERE vehicle.organization_id = p_organization_id AND vehicle.id = p_vehicle_id
      AND vehicle.passenger_capacity < v_old.passenger_count
  ) THEN
    RAISE EXCEPTION 'transport vehicle lacks passenger capacity' USING ERRCODE = 'P0001';
  END IF;
  IF p_driver_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.fleet_drivers AS driver
    WHERE driver.organization_id = p_organization_id
      AND driver.id = p_driver_id
      AND driver.status = 'available'
  ) THEN
    RAISE EXCEPTION 'transport driver is not available' USING ERRCODE = '23503';
  END IF;

  v_new_status := CASE
    WHEN v_old.status = 'in_progress' THEN 'in_progress'
    WHEN p_vehicle_id IS NULL AND p_driver_id IS NULL THEN 'requested'
    ELSE 'assigned'
  END;
  IF v_old.vehicle_id IS NOT DISTINCT FROM p_vehicle_id
    AND v_old.driver_id IS NOT DISTINCT FROM p_driver_id
    AND v_old.status = v_new_status THEN
    RETURN true;
  END IF;

  UPDATE public.transport_requests
  SET vehicle_id = p_vehicle_id,
      driver_id = p_driver_id,
      status = v_new_status
  WHERE id = p_request_id
    AND organization_id = p_organization_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'transport.request.assigned',
    'transport_request', p_request_id, 'success', p_request_idempotency,
    jsonb_build_object(
      'vehicle_id', v_old.vehicle_id,
      'driver_id', v_old.driver_id,
      'status', v_old.status
    ),
    jsonb_build_object(
      'vehicle_id', p_vehicle_id,
      'driver_id', p_driver_id,
      'status', v_new_status
    )
  );
  v_assignment_event_id := extensions.gen_random_uuid();
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'transport.request.assigned', 1,
    'transport-assignment:' || p_request_id::text || ':' || v_assignment_event_id::text,
    jsonb_build_object(
      'transport_request_id', p_request_id,
      'assignment_event_id', v_assignment_event_id
    )
  );
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assign_transport_request_without_workspace_aal2(uuid, uuid, uuid, uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;
