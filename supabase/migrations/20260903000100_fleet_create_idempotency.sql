-- Voya OS: K-045 — enforce organization-scoped idempotency for fleet creates.
--
-- Forward-only hardening for create_fleet_vehicle_v1 / create_fleet_driver_v1
-- (introduced in 20260824000100_develop_security_integrity_hardening.sql):
-- backfill legacy NULL keys, then require idempotency_key at the schema
-- boundary to match transport_requests and other command tables. RPCs keep
-- stable retry returns-same-row semantics: same (org, key) + same payload
-- returns the existing id without duplicate audit/outbox; same key with a
-- different payload raises 23505. Role gates (owner/manager/operations) and
-- audit/outbox behavior are unchanged.

ALTER TABLE public.fleet_vehicles
  ADD COLUMN IF NOT EXISTS idempotency_key text;
ALTER TABLE public.fleet_drivers
  ADD COLUMN IF NOT EXISTS idempotency_key text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.fleet_vehicles'::regclass
      AND conname = 'fleet_vehicles_idempotency_key_check'
  ) THEN
    ALTER TABLE public.fleet_vehicles
      ADD CONSTRAINT fleet_vehicles_idempotency_key_check
      CHECK (idempotency_key IS NULL OR char_length(btrim(idempotency_key)) BETWEEN 1 AND 160);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.fleet_drivers'::regclass
      AND conname = 'fleet_drivers_idempotency_key_check'
  ) THEN
    ALTER TABLE public.fleet_drivers
      ADD CONSTRAINT fleet_drivers_idempotency_key_check
      CHECK (idempotency_key IS NULL OR char_length(btrim(idempotency_key)) BETWEEN 1 AND 160);
  END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS fleet_vehicles_idempotency_idx
  ON public.fleet_vehicles (organization_id, idempotency_key);
CREATE UNIQUE INDEX IF NOT EXISTS fleet_drivers_idempotency_idx
  ON public.fleet_drivers (organization_id, idempotency_key);

-- Backfill rows created through the legacy non-idempotent RPCs (or direct
-- seed inserts) so the NOT NULL enforcement below is safe. The key embeds the
-- globally unique row id, therefore it is unique per organization as well and
-- satisfies the 1–160 check.
UPDATE public.fleet_vehicles
SET idempotency_key = 'legacy-vehicle:' || id::text
WHERE idempotency_key IS NULL;

UPDATE public.fleet_drivers
SET idempotency_key = 'legacy-driver:' || id::text
WHERE idempotency_key IS NULL;

ALTER TABLE public.fleet_vehicles ALTER COLUMN idempotency_key SET NOT NULL;
ALTER TABLE public.fleet_drivers ALTER COLUMN idempotency_key SET NOT NULL;

CREATE OR REPLACE FUNCTION public.create_fleet_vehicle_v1(
  p_organization_id uuid,
  p_display_name text,
  p_vehicle_type text,
  p_registration_code text,
  p_passenger_capacity integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_id uuid;
  v_existing public.fleet_vehicles%ROWTYPE;
  v_key text := btrim(p_idempotency_key);
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'fleet vehicle creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_display_name IS NULL OR char_length(btrim(p_display_name)) NOT BETWEEN 1 AND 120
    OR p_vehicle_type IS NULL OR p_vehicle_type NOT IN ('sedan', 'suv', 'van', 'bus', 'other')
    OR p_registration_code IS NULL OR char_length(btrim(p_registration_code)) NOT BETWEEN 1 AND 40
    OR p_passenger_capacity IS NULL OR p_passenger_capacity NOT BETWEEN 1 AND 80
    OR p_idempotency_key IS NULL OR char_length(v_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'vehicle input is invalid' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.fleet_vehicles (
    organization_id, display_name, vehicle_type, registration_code, passenger_capacity, idempotency_key
  ) VALUES (
    p_organization_id, btrim(p_display_name), p_vehicle_type, btrim(p_registration_code), p_passenger_capacity, v_key
  )
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT vehicle.* INTO v_existing
    FROM public.fleet_vehicles AS vehicle
    WHERE vehicle.organization_id = p_organization_id AND vehicle.idempotency_key = v_key;
    IF NOT FOUND
      OR v_existing.display_name <> btrim(p_display_name)
      OR v_existing.vehicle_type <> p_vehicle_type
      OR v_existing.registration_code <> btrim(p_registration_code)
      OR v_existing.passenger_capacity <> p_passenger_capacity THEN
      RAISE EXCEPTION 'idempotency key belongs to a different vehicle' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'fleet.vehicle.created', 'fleet_vehicle', v_id,
    'success', p_request_id,
    jsonb_build_object('vehicle_type', p_vehicle_type, 'passenger_capacity', p_passenger_capacity)
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'fleet.vehicle.created', 1, 'fleet-vehicle:' || v_id::text, jsonb_build_object('vehicle_id', v_id));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_fleet_driver_v1(
  p_organization_id uuid,
  p_display_name text,
  p_phone_e164 text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_id uuid;
  v_existing public.fleet_drivers%ROWTYPE;
  v_phone text := NULLIF(btrim(p_phone_e164), '');
  v_key text := btrim(p_idempotency_key);
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'fleet driver creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_display_name IS NULL OR char_length(btrim(p_display_name)) NOT BETWEEN 1 AND 160
    OR (v_phone IS NOT NULL AND v_phone !~ '^\+[1-9][0-9]{4,31}$')
    OR p_idempotency_key IS NULL OR char_length(v_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'driver input is invalid' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.fleet_drivers (organization_id, display_name, phone_e164, idempotency_key)
  VALUES (p_organization_id, btrim(p_display_name), v_phone, v_key)
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT driver.* INTO v_existing
    FROM public.fleet_drivers AS driver
    WHERE driver.organization_id = p_organization_id AND driver.idempotency_key = v_key;
    IF NOT FOUND
      OR v_existing.display_name <> btrim(p_display_name)
      OR v_existing.phone_e164 IS DISTINCT FROM v_phone THEN
      RAISE EXCEPTION 'idempotency key belongs to a different driver' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'fleet.driver.created', 'fleet_driver', v_id,
    'success', p_request_id, jsonb_build_object('has_phone', v_phone IS NOT NULL)
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'fleet.driver.created', 1, 'fleet-driver:' || v_id::text, jsonb_build_object('driver_id', v_id));
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_fleet_vehicle_v1(uuid,text,text,text,integer,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_fleet_driver_v1(uuid,text,text,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_fleet_vehicle_v1(uuid,text,text,text,integer,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_fleet_driver_v1(uuid,text,text,text,uuid) TO authenticated;

-- Legacy non-idempotent signatures stay defined for history but must not be
-- executable by the browser role; retries must go through the V1 RPCs above.
REVOKE ALL ON FUNCTION public.create_fleet_vehicle(uuid,text,text,text,integer,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_fleet_driver(uuid,text,text,uuid) FROM PUBLIC, anon, authenticated;
