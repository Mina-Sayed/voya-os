-- Voya OS: remediate validated develop security/integrity findings.
--
-- 1. Fail closed on ambiguous expired WhatsApp delivery leases.
-- 2. Serialize self-service organization onboarding per authenticated user.
-- 3. Make the full runtime role catalog provisionable through Team commands.
-- 4. Add concurrency-safe idempotent fleet creation RPCs.

-- ---------------------------------------------------------------------------
-- Outbox delivery lease ambiguity
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.claim_outbox_delivery_events(
  p_worker_id text,
  p_limit integer,
  p_lease_seconds integer
)
RETURNS SETOF public.outbox_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120 THEN
    RAISE EXCEPTION 'worker id is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 20 THEN
    RAISE EXCEPTION 'delivery batch must be between 1 and 20' USING ERRCODE = '22023';
  END IF;
  IF p_lease_seconds IS NULL OR p_lease_seconds < 1 OR p_lease_seconds > 900 THEN
    RAISE EXCEPTION 'lease duration must be between 1 and 900 seconds' USING ERRCODE = '22023';
  END IF;

  -- Meta's message send used by this worker has no application idempotency key.
  -- Once a processing lease expires we cannot know whether the provider accepted
  -- the request before the worker crashed. Re-sending would risk a duplicate
  -- customer-visible message, so quarantine that ambiguous event instead.
  UPDATE public.outbox_events AS event
  SET state = 'needs_review',
      locked_by = NULL,
      locked_until = NULL,
      last_error_code = 'worker_lease_expired_ambiguous'
  WHERE event.event_type = 'whatsapp.message.send_requested'
    AND event.state = 'processing'
    AND event.locked_until <= timezone('utc', now());

  RETURN QUERY
  WITH eligible AS (
    SELECT event.id
    FROM public.outbox_events AS event
    WHERE event.event_type IN (
      'organization.invitation.send_requested',
      'member.invitation.resent',
      'whatsapp.message.send_requested',
      'ai.run.requested'
    )
      AND (
        (event.state IN ('pending', 'retry_wait') AND event.available_at <= timezone('utc', now()))
        OR (
          event.state = 'processing'
          AND event.locked_until <= timezone('utc', now())
          AND event.event_type <> 'whatsapp.message.send_requested'
        )
      )
    ORDER BY
      CASE WHEN event.state = 'processing' THEN event.locked_until ELSE event.available_at END ASC,
      event.created_at ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.outbox_events AS event
  SET state = 'processing',
      attempts = event.attempts + 1,
      locked_by = p_worker_id,
      locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds),
      last_error_code = NULL
  FROM eligible
  WHERE event.id = eligible.id
  RETURNING event.*;
END;
$$;

-- A successful external send must not be silently recorded as successful by a
-- worker that has already lost its lease. Raising 40001 makes supabase-js
-- return an RPC error, which the existing worker handles as needs_review.
CREATE OR REPLACE FUNCTION public.mark_whatsapp_message_sent(
  p_event_id uuid,
  p_worker_id text,
  p_provider_message_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE updated_count integer;
BEGIN
  IF p_provider_message_id IS NULL OR char_length(btrim(p_provider_message_id)) NOT BETWEEN 1 AND 320 THEN
    RAISE EXCEPTION 'provider message id is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.whatsapp_message_events AS message
  SET delivery_status = 'sent',
      provider_message_id = btrim(p_provider_message_id),
      sent_at = timezone('utc', now()),
      failed_at = NULL,
      provider_error_code = NULL
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.message.send_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND message.id = (event.payload ->> 'message_id')::uuid
    AND message.organization_id = event.organization_id;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  IF updated_count <> 1 THEN
    RAISE EXCEPTION 'outbox delivery lease is stale' USING ERRCODE = '40001';
  END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_invitation_delivery_sent(
  p_event_id uuid,
  p_worker_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE updated_count integer;
BEGIN
  UPDATE public.organization_invitations AS invitation
  SET delivery_status = 'sent', updated_at = timezone('utc', now())
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type IN ('organization.invitation.send_requested', 'member.invitation.resent')
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND invitation.id = (event.payload ->> 'invitation_id')::uuid
    AND invitation.organization_id = event.organization_id;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  IF updated_count <> 1 THEN
    RAISE EXCEPTION 'outbox delivery lease is stale' USING ERRCODE = '40001';
  END IF;
  RETURN true;
END;
$$;

-- ---------------------------------------------------------------------------
-- Organization onboarding concurrency
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_organization(
  p_name text,
  p_timezone text DEFAULT 'Africa/Cairo',
  p_default_currency text DEFAULT 'EGP',
  p_request_id uuid DEFAULT NULL
)
RETURNS TABLE (organization_id uuid, membership_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_email text := auth.email();
  v_organization_id uuid;
  v_membership_id uuid;
  v_slug text;
BEGIN
  IF v_user_id IS NULL OR v_email IS NULL OR btrim(v_email) = '' THEN
    RAISE EXCEPTION 'verified user required' USING ERRCODE = '42501';
  END IF;
  IF p_name IS NULL OR char_length(btrim(p_name)) NOT BETWEEN 2 AND 160
    OR p_timezone IS NULL OR char_length(btrim(p_timezone)) NOT BETWEEN 1 AND 80
    OR p_default_currency IS NULL OR p_default_currency !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'organization onboarding input is invalid' USING ERRCODE = '22023';
  END IF;

  -- One transaction-level lock per authenticated user closes the check/insert
  -- race without imposing a global one-organization-per-user data model.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user_id::text, 0));

  IF EXISTS (
    SELECT 1 FROM public.organization_memberships
    WHERE user_id = v_user_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'user already belongs to an organization' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.profiles (id, display_name, locale)
  VALUES (v_user_id, COALESCE(NULLIF(btrim(split_part(v_email, '@', 1)), ''), 'Voya Operator'), 'ar')
  ON CONFLICT (id) DO NOTHING;

  v_slug := 'org-' || replace(gen_random_uuid()::text, '-', '');
  INSERT INTO public.organizations (name, slug, default_locale, timezone, default_currency, status, onboarding_completed_at)
  VALUES (btrim(p_name), v_slug, 'ar', btrim(p_timezone), p_default_currency, 'active', timezone('utc', now()))
  RETURNING id INTO v_organization_id;

  INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
  VALUES (v_organization_id, v_user_id, 'owner', 'active')
  RETURNING id INTO v_membership_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, reason_code, after_delta
  ) VALUES (
    v_organization_id, 'user', v_membership_id, 'organization.created',
    'organization', v_organization_id, 'success', p_request_id,
    'company_first_onboarding', jsonb_build_object('role', 'owner', 'currency', p_default_currency)
  );

  RETURN QUERY SELECT v_organization_id, v_membership_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Team role catalog
-- ---------------------------------------------------------------------------

ALTER TABLE public.organization_invitations
  DROP CONSTRAINT IF EXISTS organization_invitations_role_check;
ALTER TABLE public.organization_invitations
  DROP CONSTRAINT IF EXISTS organization_invitations_role_catalog_check;
ALTER TABLE public.organization_invitations
  ADD CONSTRAINT organization_invitations_role_catalog_check
  CHECK (role IN ('owner', 'manager', 'operator', 'operations', 'sales_agent', 'accountant', 'viewer'));

CREATE OR REPLACE FUNCTION public.invite_organization_member_v1(
  p_organization_id uuid,
  p_email text,
  p_role text,
  p_token_digest text,
  p_sealed_token text DEFAULT NULL,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_invitation_id uuid;
  v_email text := lower(btrim(p_email));
  v_role text := lower(btrim(p_role));
  v_token_digest text;
  v_expires_at timestamptz := timezone('utc', now()) + interval '72 hours';
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role = 'owner';
  IF v_actor IS NULL THEN RAISE EXCEPTION 'member invitation is not permitted' USING ERRCODE = '42501'; END IF;
  IF v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    OR v_role NOT IN ('owner', 'manager', 'operator', 'operations', 'sales_agent', 'accountant', 'viewer')
    OR p_token_digest IS NULL OR p_token_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invitation input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_sealed_token IS NOT NULL AND (
    char_length(p_sealed_token) NOT BETWEEN 20 AND 4096
    OR p_sealed_token !~ '^v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'
  ) THEN
    RAISE EXCEPTION 'sealed invitation payload is invalid' USING ERRCODE = '22023';
  END IF;

  v_token_digest := encode(extensions.digest(p_token_digest, 'sha256'), 'hex');
  IF EXISTS (
    SELECT 1
    FROM public.organization_memberships AS membership
    JOIN auth.users AS account ON account.id = membership.user_id
    WHERE membership.organization_id = p_organization_id
      AND lower(account.email) = v_email
      AND membership.status = 'active'
  ) THEN
    RAISE EXCEPTION 'user is already a member' USING ERRCODE = '23505';
  END IF;

  UPDATE public.organization_invitations
  SET status = 'revoked', updated_at = timezone('utc', now())
  WHERE organization_id = p_organization_id AND normalized_email = v_email AND status = 'pending';

  INSERT INTO public.organization_invitations (
    organization_id, normalized_email, role, token_digest, expires_at, created_by_membership_id
  ) VALUES (
    p_organization_id, v_email, v_role, v_token_digest, v_expires_at, v_actor
  ) RETURNING id INTO v_invitation_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'member.invited', 'organization_invitation',
    v_invitation_id, 'success', p_request_id, jsonb_build_object('email', v_email, 'role', v_role)
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id,
    'organization.invitation.send_requested',
    1,
    'organization-invitation:' || v_invitation_id::text,
    jsonb_build_object(
      'invitation_id', v_invitation_id,
      'email', v_email,
      'role', v_role,
      'sealed_token', p_sealed_token,
      'expires_at', v_expires_at
    )
  );
  RETURN v_invitation_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_organization_members(p_organization_id uuid)
RETURNS TABLE (
  id uuid, user_id uuid, display_name text, role text, status text, created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_role text;
BEGIN
  SELECT membership.role INTO v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'accountant', 'viewer') THEN
    RAISE EXCEPTION 'member read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT membership.id, membership.user_id, COALESCE(profile.display_name, membership.user_id::text),
    membership.role, membership.status, membership.created_at
  FROM public.organization_memberships AS membership
  LEFT JOIN public.profiles AS profile ON profile.id = membership.user_id
  WHERE membership.organization_id = p_organization_id
  ORDER BY (membership.role = 'owner') DESC, membership.created_at ASC, membership.id ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.change_organization_member_role(
  p_organization_id uuid, p_membership_id uuid, p_role text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid; v_target public.organization_memberships%ROWTYPE; v_requested_role text; v_new_role text;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role = 'owner';
  IF v_actor IS NULL THEN RAISE EXCEPTION 'member role change is not permitted' USING ERRCODE = '42501'; END IF;
  v_requested_role := lower(btrim(p_role));
  IF v_requested_role NOT IN ('owner', 'manager', 'operator', 'operations', 'sales_agent', 'accountant', 'viewer') THEN
    RAISE EXCEPTION 'member role is invalid' USING ERRCODE = '22023';
  END IF;
  v_new_role := CASE v_requested_role WHEN 'operator' THEN 'operations' ELSE v_requested_role END;

  -- Serialize all role changes in one organization before checking the
  -- last-owner invariant. Locking only the target membership lets two owners
  -- downgrade different owner rows concurrently and leave zero owners.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text, 1)
  );

  SELECT membership.* INTO v_target
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.id = p_membership_id
  FOR UPDATE;
  IF NOT FOUND OR v_target.status <> 'active' THEN RAISE EXCEPTION 'member is invalid' USING ERRCODE = '23503'; END IF;
  IF v_target.role = 'owner' AND v_new_role <> 'owner'
    AND (SELECT count(*) FROM public.organization_memberships WHERE organization_id = p_organization_id AND role = 'owner' AND status = 'active') <= 1 THEN
    RAISE EXCEPTION 'last active owner cannot be downgraded' USING ERRCODE = '42501';
  END IF;
  UPDATE public.organization_memberships
  SET role = v_new_role, updated_at = timezone('utc', now())
  WHERE organization_id = p_organization_id AND id = p_membership_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'member.role_changed', 'organization_membership',
    p_membership_id, 'success', p_request_id,
    jsonb_build_object('role', v_target.role), jsonb_build_object('role', v_new_role)
  );
  RETURN true;
END;
$$;

-- ---------------------------------------------------------------------------
-- Fleet idempotency
-- ---------------------------------------------------------------------------

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

-- The legacy signatures do not accept an idempotency key. Keep them defined for
-- historical compatibility, but remove their browser execution boundary so a
-- stale client cannot bypass the retry-safe V1 RPCs above.
REVOKE ALL ON FUNCTION public.create_fleet_vehicle(uuid,text,text,text,integer,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_fleet_driver(uuid,text,text,uuid) FROM PUBLIC, anon, authenticated;
