-- Bind cancellation commands to an exact booking, payload and approval.
CREATE OR REPLACE FUNCTION public.cancel_booking_draft_without_workspace_aal2(
  p_organization_id uuid, p_booking_id uuid, p_reason text, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid; v_booking public.bookings%ROWTYPE;
  v_binding public.booking_v1_command_idempotency%ROWTYPE;
  v_payload_hash text := encode(extensions.digest(jsonb_build_object('reason',btrim(p_reason))::text,'sha256'),'hex');
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'draft cancellation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000 OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'draft cancellation input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503'; END IF;

  INSERT INTO public.booking_v1_command_idempotency
    (organization_id, command_name, idempotency_key, booking_id, payload_hash)
  VALUES (p_organization_id, 'booking.cancel.draft', btrim(p_idempotency_key), p_booking_id, v_payload_hash)
  ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN
    SELECT binding.* INTO STRICT v_binding
    FROM public.booking_v1_command_idempotency AS binding
    WHERE binding.organization_id = p_organization_id AND binding.command_name = 'booking.cancel.draft'
      AND binding.idempotency_key = btrim(p_idempotency_key);
    IF v_binding.booking_id IS DISTINCT FROM p_booking_id OR v_binding.payload_hash IS DISTINCT FROM v_payload_hash
      THEN
      RAISE EXCEPTION 'cancellation key belongs to a different or unknown request' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;
  IF v_booking.status <> 'draft' THEN RAISE EXCEPTION 'only a draft booking can be cancelled directly' USING ERRCODE = '22023'; END IF;
  UPDATE public.bookings SET status = 'cancelled', version = version + 1 WHERE organization_id = p_organization_id AND id = p_booking_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta) VALUES (p_organization_id, 'user', v_actor, 'booking.draft_cancelled', 'booking', p_booking_id, 'success', p_request_id, 'user_requested', jsonb_build_object('reason', btrim(p_reason)));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.request_booking_cancellation_without_workspace_aal2(
  p_organization_id uuid, p_booking_id uuid, p_reason text, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid; v_booking public.bookings%ROWTYPE; v_snapshot jsonb; v_approval uuid;
  v_binding public.booking_v1_command_idempotency%ROWTYPE;
  v_payload_hash text;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'booking cancellation request is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000 OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'booking cancellation input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503'; END IF;
  v_payload_hash := encode(extensions.digest(jsonb_build_object('reason', btrim(p_reason), 'requester', v_actor)::text, 'sha256'), 'hex');

  INSERT INTO public.booking_v1_command_idempotency
    (organization_id, command_name, idempotency_key, booking_id, payload_hash)
  VALUES (p_organization_id, 'booking.cancel.request', btrim(p_idempotency_key), p_booking_id, v_payload_hash)
  ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN
    SELECT binding.* INTO STRICT v_binding
    FROM public.booking_v1_command_idempotency AS binding
    WHERE binding.organization_id = p_organization_id AND binding.command_name = 'booking.cancel.request'
      AND binding.idempotency_key = btrim(p_idempotency_key);
    IF v_binding.booking_id IS DISTINCT FROM p_booking_id OR v_binding.payload_hash IS DISTINCT FROM v_payload_hash
      OR v_binding.result_id IS NULL THEN
      RAISE EXCEPTION 'cancellation key belongs to a different or unknown request' USING ERRCODE = '23505';
    END IF;
    RETURN v_binding.result_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS reviewer
    WHERE reviewer.organization_id = p_organization_id AND reviewer.status = 'active'
      AND reviewer.role IN ('owner', 'manager') AND reviewer.id <> v_actor
  ) THEN
    RAISE EXCEPTION 'APPROVAL_NOT_OPERATIONALLY_READY' USING ERRCODE = '42501';
  END IF;
  IF v_booking.status <> 'confirmed' THEN RAISE EXCEPTION 'only a confirmed booking can be cancelled through approval' USING ERRCODE = '22023'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.approval_requests AS existing_request
    WHERE existing_request.organization_id = p_organization_id
      AND existing_request.resource_type = 'booking' AND existing_request.resource_id = p_booking_id
      AND existing_request.proposed_action = 'booking.cancel'
      AND existing_request.status IN ('pending', 'approved') AND existing_request.expires_at > clock_timestamp()
      AND existing_request.proposal_snapshot->>'booking_version' = v_booking.version::text
  ) THEN
    RAISE EXCEPTION 'an active cancellation already exists' USING ERRCODE = '22023';
  END IF;
  v_snapshot := jsonb_build_object('booking_id', p_booking_id, 'booking_version', v_booking.version, 'reason', btrim(p_reason));
  INSERT INTO public.approval_requests (organization_id, resource_type, resource_id, proposed_action, proposal_snapshot, snapshot_hash, requester_membership_id, expires_at) VALUES (p_organization_id, 'booking', p_booking_id, 'booking.cancel', v_snapshot, encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'), v_actor, clock_timestamp() + interval '24 hours') RETURNING id INTO v_approval;
  UPDATE public.booking_v1_command_idempotency
  SET result_id = v_approval
  WHERE organization_id = p_organization_id AND command_name = 'booking.cancel.request'
    AND idempotency_key = btrim(p_idempotency_key);
  INSERT INTO public.notifications (organization_id, recipient_membership_id, category, title, body, resource_type, resource_id, dedupe_key)
  SELECT p_organization_id, membership.id, 'approval', 'إلغاء حجز يحتاج اعتمادًا', 'يوجد طلب إلغاء حجز ينتظر مراجعة مستقلة.', 'booking', p_booking_id, 'booking-cancel-approval:' || v_approval::text || ':' || membership.id::text
  FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.status = 'active' AND membership.role IN ('owner', 'manager') AND membership.id <> v_actor;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta) VALUES (p_organization_id, 'user', v_actor, 'booking.cancellation_requested', 'booking', p_booking_id, 'success', p_request_id, jsonb_build_object('approval_request_id', v_approval, 'reason', btrim(p_reason)));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'booking.cancellation.requested', 1, 'booking-cancellation:' || v_approval::text, jsonb_build_object('approval_request_id', v_approval, 'booking_id', p_booking_id));
  RETURN v_approval;
END;
$$;

CREATE OR REPLACE FUNCTION public.execute_booking_cancellation_v2(
  p_organization_id uuid, p_booking_id uuid, p_approval_request_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid; v_booking public.bookings%ROWTYPE; v_approval public.approval_requests%ROWTYPE; v_snapshot jsonb; v_now timestamptz;
  v_binding public.booking_v1_command_idempotency%ROWTYPE;
  v_payload_hash text;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'booking cancellation execution is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_approval_request_id IS NULL OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'cancellation execution idempotency key is invalid' USING ERRCODE = '22023'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503'; END IF;
  v_payload_hash := encode(extensions.digest(p_approval_request_id::text, 'sha256'), 'hex');

  INSERT INTO public.booking_v1_command_idempotency
    (organization_id, command_name, idempotency_key, booking_id, payload_hash)
  VALUES (p_organization_id, 'booking.cancel.execute', btrim(p_idempotency_key), p_booking_id, v_payload_hash)
  ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN
    SELECT binding.* INTO STRICT v_binding
    FROM public.booking_v1_command_idempotency AS binding
    WHERE binding.organization_id = p_organization_id AND binding.command_name = 'booking.cancel.execute'
      AND binding.idempotency_key = btrim(p_idempotency_key);
    IF v_binding.booking_id IS DISTINCT FROM p_booking_id OR v_binding.payload_hash IS DISTINCT FROM v_payload_hash
      OR v_binding.result_id IS DISTINCT FROM p_approval_request_id THEN
      RAISE EXCEPTION 'cancellation key belongs to a different or unknown request' USING ERRCODE = '23505';
    END IF;
    RETURN true;
  END IF;
  IF v_booking.status <> 'confirmed' THEN RAISE EXCEPTION 'booking is not cancellable' USING ERRCODE = '22023'; END IF;
  SELECT request.* INTO v_approval FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id AND request.id = p_approval_request_id
    AND request.resource_type = 'booking' AND request.resource_id = p_booking_id
    AND request.proposed_action = 'booking.cancel' AND request.status = 'approved'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'approved cancellation is required' USING ERRCODE = '22023'; END IF;
  IF v_approval.requester_membership_id = v_actor THEN RAISE EXCEPTION 'requester cannot execute their own cancellation' USING ERRCODE = '42501'; END IF;
  v_now := clock_timestamp();
  IF v_approval.expires_at IS NULL OR v_approval.expires_at <= v_now THEN RAISE EXCEPTION 'cancellation approval is expired' USING ERRCODE = '22023'; END IF;
  v_snapshot := jsonb_build_object('booking_id', p_booking_id, 'booking_version', v_booking.version, 'reason', v_approval.proposal_snapshot->>'reason');
  IF v_approval.proposal_snapshot <> v_snapshot OR v_approval.snapshot_hash <> encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex') THEN RAISE EXCEPTION 'cancellation snapshot is invalid' USING ERRCODE = '22023'; END IF;
  UPDATE public.booking_v1_command_idempotency
  SET result_id = v_approval.id
  WHERE organization_id = p_organization_id AND command_name = 'booking.cancel.execute'
    AND idempotency_key = btrim(p_idempotency_key);
  UPDATE public.bookings SET status = 'cancelled', version = version + 1 WHERE organization_id = p_organization_id AND id = p_booking_id;
  UPDATE public.approval_requests SET status = 'executed', executed_at = v_now, updated_at = v_now WHERE organization_id = p_organization_id AND id = v_approval.id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta) VALUES (p_organization_id, 'user', v_actor, 'booking.cancelled', 'booking', p_booking_id, 'success', p_request_id, 'approved', jsonb_build_object('approval_request_id', v_approval.id, 'reason', v_approval.proposal_snapshot->>'reason'));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'booking.cancelled', 1, 'booking-cancelled:' || p_booking_id::text, jsonb_build_object('booking_id', p_booking_id, 'approval_request_id', v_approval.id));
  RETURN true;
END;
$$;

-- Keep the previous signature usable when there is exactly one live approval.
CREATE OR REPLACE FUNCTION public.execute_booking_cancellation_without_workspace_aal2(
  p_organization_id uuid, p_booking_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_approval_id uuid; v_candidates uuid[];
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
      AND membership.status = 'active' AND membership.role IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'booking cancellation execution is not permitted' USING ERRCODE = '42501';
  END IF;
  PERFORM 1 FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503'; END IF;
  SELECT binding.result_id INTO v_approval_id FROM public.booking_v1_command_idempotency AS binding
  WHERE binding.organization_id = p_organization_id AND binding.command_name = 'booking.cancel.execute'
    AND binding.idempotency_key = btrim(p_idempotency_key) AND binding.booking_id = p_booking_id;
  IF v_approval_id IS NULL THEN
    SELECT array_agg(request.id) INTO v_candidates FROM public.approval_requests AS request
    WHERE request.organization_id = p_organization_id AND request.resource_type = 'booking'
      AND request.resource_id = p_booking_id AND request.proposed_action = 'booking.cancel'
      AND request.status = 'approved' AND request.expires_at > clock_timestamp();
    IF coalesce(cardinality(v_candidates), 0) <> 1 THEN
      RAISE EXCEPTION 'select one specific cancellation approval' USING ERRCODE = '22023';
    END IF;
    v_approval_id := v_candidates[1];
  END IF;
  RETURN public.execute_booking_cancellation_v2(p_organization_id, p_booking_id, v_approval_id, p_idempotency_key, p_request_id);
END;
$$;


CREATE OR REPLACE FUNCTION public.list_executable_booking_changes_v1_without_workspace_aal2(
  p_organization_id uuid
)
RETURNS TABLE (
  booking_id uuid,
  approval_request_id uuid,
  proposed_action text,
  expires_at timestamptz,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking executable approval read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT DISTINCT ON (request.resource_id, request.proposed_action)
    request.resource_id,
    request.id,
    request.proposed_action,
    request.expires_at,
    request.created_at
  FROM public.approval_requests AS request
  JOIN public.bookings AS booking
    ON booking.organization_id = request.organization_id
   AND booking.id = request.resource_id
  WHERE request.organization_id = p_organization_id
    AND request.resource_type = 'booking'
    AND request.proposed_action IN ('booking.confirm', 'booking.amend', 'booking.cancel')
    AND request.status = 'approved'
    AND request.expires_at IS NOT NULL
    AND request.expires_at > timezone('utc', now())
    AND request.requester_membership_id <> v_actor
    AND request.snapshot_hash = encode(extensions.digest(request.proposal_snapshot::text, 'sha256'), 'hex')
    AND (
      (
        request.proposed_action = 'booking.confirm'
        AND booking.status = 'pending_approval'
        AND EXISTS (
          SELECT 1
          FROM public.properties AS confirmation_property
          WHERE confirmation_property.organization_id = booking.organization_id
            AND confirmation_property.id = booking.property_id
            AND confirmation_property.status = 'active'
        )
        AND request.proposal_snapshot = jsonb_build_object(
          'booking_id', booking.id,
          'booking_version', booking.version,
          'property_id', booking.property_id,
          'client_id', booking.client_id,
          'check_in', booking.check_in,
          'check_out', booking.check_out,
          'agreed_total_amount_minor', booking.agreed_total_amount_minor,
          'currency', booking.currency,
          'status', 'draft'
        )
      )
      OR (
        request.proposed_action = 'booking.amend'
        AND booking.status = 'confirmed'
        AND request.proposal_snapshot->>'booking_version' ~ '^[0-9]+$'
        AND request.proposal_snapshot->>'property_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND request.proposal_snapshot->>'client_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND (request.proposal_snapshot->>'booking_version')::integer = booking.version
        AND EXISTS (
          SELECT 1
          FROM public.properties AS amendment_property
          WHERE amendment_property.organization_id = booking.organization_id
            AND amendment_property.id = (request.proposal_snapshot->>'property_id')::uuid
            AND amendment_property.status = 'active'
        )
        AND EXISTS (
          SELECT 1
          FROM public.clients AS amendment_client
          WHERE amendment_client.organization_id = booking.organization_id
            AND amendment_client.id = (request.proposal_snapshot->>'client_id')::uuid
            AND amendment_client.archived_at IS NULL
        )
      )
      OR (
        request.proposed_action = 'booking.cancel'
        AND booking.status = 'confirmed'
        AND char_length(btrim(request.proposal_snapshot->>'reason')) BETWEEN 1 AND 1000
        AND request.proposal_snapshot = jsonb_build_object(
          'booking_id', booking.id, 'booking_version', booking.version,
          'reason', request.proposal_snapshot->>'reason'
        )
      )
    )
  ORDER BY request.resource_id, request.proposed_action, request.created_at DESC, request.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.execute_booking_cancellation_v2(uuid, uuid, uuid, text, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.execute_booking_cancellation_v2(uuid, uuid, uuid, text, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.cancel_booking_draft_without_workspace_aal2(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.request_booking_cancellation_without_workspace_aal2(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.execute_booking_cancellation_without_workspace_aal2(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_executable_booking_changes_v1_without_workspace_aal2(uuid) FROM PUBLIC, anon, authenticated, service_role;
