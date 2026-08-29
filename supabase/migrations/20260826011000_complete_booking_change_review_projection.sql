-- Complete the safe reviewer projection for both amendment and cancellation.
-- Cancellation snapshots intentionally store only booking_version + reason; the
-- current booking row is safe to project because decide_booking_approval now
-- rejects the request if that version no longer matches at decision time.

CREATE OR REPLACE FUNCTION public.list_approval_requests_v2(
  p_organization_id uuid,
  p_limit integer DEFAULT 50
)
RETURNS TABLE (
  id uuid,
  resource_type text,
  resource_id uuid,
  proposed_action text,
  status text,
  expires_at timestamptz,
  created_at timestamptz,
  proposal_summary jsonb,
  requester_display_name text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_membership_id uuid;
  v_role text;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'approval request limit is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id, membership.role INTO v_membership_id, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_membership_id IS NULL OR v_role = 'viewer' THEN
    RAISE EXCEPTION 'approval request read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT request.id,
    request.resource_type,
    request.resource_id,
    request.proposed_action,
    request.status,
    request.expires_at,
    request.created_at,
    CASE request.proposed_action
      WHEN 'booking.confirm' THEN jsonb_build_object(
        'checkIn', request.proposal_snapshot->>'check_in',
        'checkOut', request.proposal_snapshot->>'check_out',
        'amountMinor', request.proposal_snapshot->>'agreed_total_amount_minor',
        'currency', request.proposal_snapshot->>'currency',
        'propertyId', request.proposal_snapshot->>'property_id',
        'clientId', request.proposal_snapshot->>'client_id'
      )
      WHEN 'booking.amend' THEN jsonb_build_object(
        'checkIn', request.proposal_snapshot->>'check_in',
        'checkOut', request.proposal_snapshot->>'check_out',
        'amountMinor', request.proposal_snapshot->>'agreed_total_amount_minor',
        'currency', request.proposal_snapshot->>'currency',
        'reason', request.proposal_snapshot->>'reason',
        'propertyId', request.proposal_snapshot->>'property_id',
        'clientId', request.proposal_snapshot->>'client_id',
        'propertyLabel', (
          SELECT property_record.code || ' — ' || property_record.name
          FROM public.properties AS property_record
          WHERE property_record.organization_id = request.organization_id
            AND property_record.id = (request.proposal_snapshot->>'property_id')::uuid
        ),
        'clientLabel', (
          SELECT client_record.display_name
          FROM public.clients AS client_record
          WHERE client_record.organization_id = request.organization_id
            AND client_record.id = (request.proposal_snapshot->>'client_id')::uuid
        )
      )
      WHEN 'booking.cancel' THEN jsonb_build_object(
        'checkIn', booking_record.check_in::text,
        'checkOut', booking_record.check_out::text,
        'amountMinor', booking_record.agreed_total_amount_minor::text,
        'currency', booking_record.currency,
        'reason', request.proposal_snapshot->>'reason',
        'propertyId', booking_record.property_id::text,
        'clientId', booking_record.client_id::text,
        'propertyLabel', property_record.code || ' — ' || property_record.name,
        'clientLabel', COALESCE(client_record.display_name, 'عميل غير مرتبط')
      )
      ELSE '{}'::jsonb
    END,
    profile.display_name
  FROM public.approval_requests AS request
  JOIN public.organization_memberships AS requester
    ON requester.organization_id = request.organization_id
   AND requester.id = request.requester_membership_id
  LEFT JOIN public.profiles AS profile
    ON profile.id = requester.user_id
  LEFT JOIN public.bookings AS booking_record
    ON booking_record.organization_id = request.organization_id
   AND booking_record.id = request.resource_id
   AND request.resource_type = 'booking'
  LEFT JOIN public.properties AS property_record
    ON property_record.organization_id = booking_record.organization_id
   AND property_record.id = booking_record.property_id
  LEFT JOIN public.clients AS client_record
    ON client_record.organization_id = booking_record.organization_id
   AND client_record.id = booking_record.client_id
  WHERE request.organization_id = p_organization_id
    AND (v_role IN ('owner', 'manager') OR request.requester_membership_id = v_membership_id)
  ORDER BY request.created_at DESC, request.id DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.list_approval_requests_v2(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_approval_requests_v2(uuid, integer) TO authenticated;

-- Bind execution idempotency to the exact approved amendment. A committed row
-- is the durable result marker: because it is written in the same transaction
-- as the booking mutation, its existence means that exact execution committed.
-- Replays therefore return before mutable booking/approval checks, while reuse
-- of the key for another booking or approval fails closed.
CREATE OR REPLACE FUNCTION public.execute_booking_amendment(
  p_organization_id uuid,
  p_booking_id uuid,
  p_approval_request_id uuid,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_booking public.bookings%ROWTYPE;
  v_approval public.approval_requests%ROWTYPE;
  v_snapshot jsonb;
  v_now timestamptz;
  v_new_property uuid;
  v_new_client uuid;
  v_new_amount bigint;
  v_new_currency text;
  v_key text := btrim(p_idempotency_key);
  v_existing_booking_id uuid;
  v_existing_approval_id uuid;
  v_inserted_count integer;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking amendment execution is not permitted' USING ERRCODE = '42501';
  END IF;

  IF p_booking_id IS NULL
    OR p_approval_request_id IS NULL
    OR p_idempotency_key IS NULL
    OR char_length(v_key) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'amendment execution input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT idempotency.booking_id, idempotency.result_id
    INTO v_existing_booking_id, v_existing_approval_id
  FROM public.booking_v1_command_idempotency AS idempotency
  WHERE idempotency.organization_id = p_organization_id
    AND idempotency.command_name = 'booking.amend.execute'
    AND idempotency.idempotency_key = v_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_booking_id IS DISTINCT FROM p_booking_id
      OR v_existing_approval_id IS NULL
      OR v_existing_approval_id IS DISTINCT FROM p_approval_request_id THEN
      RAISE EXCEPTION 'idempotency key belongs to a different amendment execution' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  INSERT INTO public.booking_v1_command_idempotency (
    organization_id, command_name, idempotency_key, booking_id, result_id
  ) VALUES (
    p_organization_id, 'booking.amend.execute', v_key, p_booking_id, p_approval_request_id
  )
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  IF v_inserted_count = 0 THEN
    SELECT idempotency.booking_id, idempotency.result_id
      INTO v_existing_booking_id, v_existing_approval_id
    FROM public.booking_v1_command_idempotency AS idempotency
    WHERE idempotency.organization_id = p_organization_id
      AND idempotency.command_name = 'booking.amend.execute'
      AND idempotency.idempotency_key = v_key
    FOR UPDATE;

    IF NOT FOUND
      OR v_existing_booking_id IS DISTINCT FROM p_booking_id
      OR v_existing_approval_id IS NULL
      OR v_existing_approval_id IS DISTINCT FROM p_approval_request_id THEN
      RAISE EXCEPTION 'idempotency key belongs to a different amendment execution' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'confirmed' THEN
    RAISE EXCEPTION 'booking is not amendable' USING ERRCODE = '22023';
  END IF;

  SELECT request.* INTO v_approval
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_approval_request_id
    AND request.resource_type = 'booking'
    AND request.resource_id = p_booking_id
    AND request.proposed_action = 'booking.amend'
    AND request.status = 'approved'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'approved amendment is required' USING ERRCODE = '42501';
  END IF;
  IF v_approval.requester_membership_id = v_actor THEN
    RAISE EXCEPTION 'requester cannot execute their own amendment' USING ERRCODE = '42501';
  END IF;

  v_now := clock_timestamp();
  IF v_approval.expires_at IS NULL OR v_approval.expires_at <= v_now THEN
    RAISE EXCEPTION 'amendment approval is expired' USING ERRCODE = '42501';
  END IF;

  v_new_property := (v_approval.proposal_snapshot->>'property_id')::uuid;
  v_new_client := (v_approval.proposal_snapshot->>'client_id')::uuid;
  v_new_amount := (v_approval.proposal_snapshot->>'agreed_total_amount_minor')::bigint;
  v_new_currency := v_approval.proposal_snapshot->>'currency';
  v_snapshot := jsonb_build_object(
    'booking_id', v_booking.id,
    'booking_version', v_booking.version,
    'property_id', v_new_property,
    'client_id', v_new_client,
    'check_in', (v_approval.proposal_snapshot->>'check_in')::date,
    'check_out', (v_approval.proposal_snapshot->>'check_out')::date,
    'agreed_total_amount_minor', v_new_amount,
    'currency', v_new_currency,
    'reason', v_approval.proposal_snapshot->>'reason'
  );
  IF v_approval.proposal_snapshot <> v_snapshot
    OR v_approval.snapshot_hash <> encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'amendment snapshot is invalid' USING ERRCODE = '22023';
  END IF;
  IF (v_approval.proposal_snapshot->>'booking_version')::integer <> v_booking.version THEN
    RAISE EXCEPTION 'booking version is stale' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.properties
    WHERE organization_id = p_organization_id
      AND id = v_new_property
      AND status = 'active'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.clients
    WHERE organization_id = p_organization_id
      AND id = v_new_client
      AND archived_at IS NULL
  ) THEN
    RAISE EXCEPTION 'amendment property or client is invalid' USING ERRCODE = '23503';
  END IF;

  UPDATE public.bookings
  SET property_id = v_new_property,
      client_id = v_new_client,
      check_in = (v_approval.proposal_snapshot->>'check_in')::date,
      check_out = (v_approval.proposal_snapshot->>'check_out')::date,
      agreed_total_amount_minor = v_new_amount,
      currency = v_new_currency,
      commercial_completion_status = 'complete',
      version = version + 1
  WHERE organization_id = p_organization_id
    AND id = p_booking_id;

  UPDATE public.approval_requests
  SET status = 'executed',
      executed_at = v_now,
      updated_at = v_now
  WHERE organization_id = p_organization_id
    AND id = v_approval.id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.amended',
    'booking', p_booking_id, 'success', p_request_id,
    jsonb_build_object(
      'approval_request_id', v_approval.id,
      'booking_version', v_booking.version,
      'reason', v_approval.proposal_snapshot->>'reason'
    )
  );

  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id,
    'booking.amended',
    1,
    'booking-amended:' || p_booking_id::text || ':' || v_booking.version::text,
    jsonb_build_object('booking_id', p_booking_id, 'approval_request_id', v_approval.id)
  );

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.execute_booking_amendment(uuid, uuid, uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_booking_amendment(uuid, uuid, uuid, text, uuid) TO authenticated;

-- All commands capable of reducing the active-owner set must serialize on the
-- same organization lock as change_organization_member_role. This makes the
-- last-owner invariant a transaction-level invariant across downgrade,
-- suspension, and removal rather than only inside one RPC.
CREATE OR REPLACE FUNCTION public.suspend_organization_member(
  p_organization_id uuid,
  p_membership_id uuid,
  p_reason text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_target public.organization_memberships%ROWTYPE;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role = 'owner';
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'member suspension is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'member suspension reason is required' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text, 1)
  );

  SELECT membership.* INTO v_target
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.id = p_membership_id
  FOR UPDATE;
  IF NOT FOUND OR v_target.status <> 'active' THEN
    RAISE EXCEPTION 'member is invalid' USING ERRCODE = '23503';
  END IF;
  IF v_target.role = 'owner'
    AND (
      SELECT count(*)
      FROM public.organization_memberships
      WHERE organization_id = p_organization_id
        AND role = 'owner'
        AND status = 'active'
    ) <= 1 THEN
    RAISE EXCEPTION 'last active owner cannot be suspended' USING ERRCODE = '42501';
  END IF;

  UPDATE public.organization_memberships
  SET status = 'suspended', updated_at = timezone('utc', now())
  WHERE organization_id = p_organization_id
    AND id = p_membership_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, reason_code, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'member.suspended',
    'organization_membership', p_membership_id, 'success', p_request_id,
    'owner_action', jsonb_build_object('reason', btrim(p_reason))
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_organization_member(
  p_organization_id uuid,
  p_membership_id uuid,
  p_reason text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_target public.organization_memberships%ROWTYPE;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role = 'owner';
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'member removal is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'member removal reason is required' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text, 1)
  );

  SELECT membership.* INTO v_target
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.id = p_membership_id
  FOR UPDATE;
  IF NOT FOUND OR v_target.status = 'suspended' THEN
    RAISE EXCEPTION 'member is invalid' USING ERRCODE = '23503';
  END IF;
  IF v_target.role = 'owner'
    AND (
      SELECT count(*)
      FROM public.organization_memberships
      WHERE organization_id = p_organization_id
        AND role = 'owner'
        AND status = 'active'
    ) <= 1 THEN
    RAISE EXCEPTION 'last active owner cannot be removed' USING ERRCODE = '42501';
  END IF;

  UPDATE public.organization_memberships
  SET status = 'suspended', updated_at = timezone('utc', now())
  WHERE organization_id = p_organization_id
    AND id = p_membership_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, reason_code, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'member.removed',
    'organization_membership', p_membership_id, 'success', p_request_id,
    'owner_action', jsonb_build_object('reason', btrim(p_reason))
  );
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.suspend_organization_member(uuid, uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.remove_organization_member(uuid, uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.suspend_organization_member(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_organization_member(uuid, uuid, text, uuid) TO authenticated;
