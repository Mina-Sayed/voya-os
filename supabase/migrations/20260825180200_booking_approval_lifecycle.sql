-- Voya OS: approval expiry renewal and checked-in decision support.
CREATE OR REPLACE FUNCTION public.request_commercial_booking_approval(
  p_organization_id uuid,
  p_booking_id uuid,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_booking public.bookings%ROWTYPE;
  v_existing public.approval_requests%ROWTYPE;
  v_approval uuid;
  v_snapshot jsonb;
  v_now timestamptz;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'commercial booking approval request is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'booking approval idempotency key is invalid' USING ERRCODE = '22023';
  END IF;
  IF (
    SELECT count(*) FROM public.organization_memberships
    WHERE organization_id = p_organization_id
      AND status = 'active'
      AND role IN ('owner', 'manager')
  ) < 2 THEN
    RAISE EXCEPTION 'APPROVAL_NOT_OPERATIONALLY_READY' USING ERRCODE = '42501';
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503';
  END IF;

  v_now := clock_timestamp();
  UPDATE public.approval_requests
  SET status = 'expired', updated_at = v_now
  WHERE organization_id = p_organization_id
    AND resource_type = 'booking'
    AND resource_id = p_booking_id
    AND proposed_action = 'booking.confirm'
    AND status = 'pending'
    AND expires_at IS NOT NULL
    AND expires_at <= v_now;

  IF v_booking.status = 'pending_approval' THEN
    SELECT request.* INTO v_existing
    FROM public.approval_requests AS request
    WHERE request.organization_id = p_organization_id
      AND request.resource_type = 'booking'
      AND request.resource_id = p_booking_id
      AND request.proposed_action = 'booking.confirm'
      AND request.status = 'pending'
      AND (request.expires_at IS NULL OR request.expires_at > v_now)
    ORDER BY request.created_at DESC
    LIMIT 1;
    IF FOUND THEN
      RETURN v_existing.id;
    END IF;
  ELSIF v_booking.status <> 'draft' THEN
    RAISE EXCEPTION 'booking cannot request commercial approval in its current state' USING ERRCODE = '22023';
  END IF;

  IF v_booking.commercial_completion_status <> 'complete'
    OR v_booking.agreed_total_amount_minor IS NULL
    OR v_booking.currency IS NULL THEN
    RAISE EXCEPTION 'booking commercial completion is required' USING ERRCODE = '22023';
  END IF;

  v_snapshot := jsonb_build_object(
    'booking_id', v_booking.id,
    'booking_version', v_booking.version,
    'property_id', v_booking.property_id,
    'client_id', v_booking.client_id,
    'check_in', v_booking.check_in,
    'check_out', v_booking.check_out,
    'agreed_total_amount_minor', v_booking.agreed_total_amount_minor,
    'currency', v_booking.currency,
    'status', 'draft'
  );

  INSERT INTO public.approval_requests (
    organization_id, resource_type, resource_id, proposed_action, proposal_snapshot,
    snapshot_hash, requester_membership_id, expires_at
  ) VALUES (
    p_organization_id, 'booking', p_booking_id, 'booking.confirm', v_snapshot,
    encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'), v_actor,
    v_now + interval '24 hours'
  ) RETURNING id INTO v_approval;

  UPDATE public.bookings
  SET status = 'pending_approval'
  WHERE organization_id = p_organization_id AND id = p_booking_id;

  INSERT INTO public.notifications (
    organization_id, recipient_membership_id, category, title, body,
    resource_type, resource_id, dedupe_key
  )
  SELECT p_organization_id, membership.id, 'approval', 'حجز يحتاج اعتمادًا',
    'يوجد حجز تجاري جديد ينتظر مراجعة مستقلة.', 'booking', p_booking_id,
    'booking-approval:' || v_approval::text || ':' || membership.id::text
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager')
    AND membership.id <> v_actor;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.commercial_approval_requested',
    'booking', p_booking_id, 'success', p_request_id,
    jsonb_build_object(
      'approval_request_id', v_approval,
      'snapshot_hash', encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex')
    )
  );

  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'booking.commercial_approval.requested', 1,
    'booking-commercial-approval:' || v_approval::text,
    jsonb_build_object('approval_request_id', v_approval, 'booking_id', p_booking_id)
  );
  RETURN v_approval;
END;
$$;

-- Approval decisions for amendments/cancellations stay actionable while the guest is checked in.
CREATE OR REPLACE FUNCTION public.decide_booking_approval(
  p_organization_id uuid,
  p_approval_request_id uuid,
  p_decision text,
  p_reason text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_booking_id uuid;
  v_request public.approval_requests%ROWTYPE;
  v_booking public.bookings%ROWTYPE;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking approval decision is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_decision IS NULL
    OR p_decision NOT IN ('approved', 'rejected')
    OR p_reason IS NULL
    OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'approval decision is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT request.resource_id INTO v_booking_id
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_approval_request_id
    AND request.resource_type = 'booking'
    AND request.proposed_action IN ('booking.confirm', 'booking.amend', 'booking.cancel');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'approval request is no longer actionable' USING ERRCODE = '22023';
  END IF;

  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id AND booking.id = v_booking_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking is no longer awaiting approval' USING ERRCODE = '22023';
  END IF;

  SELECT request.* INTO v_request
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_approval_request_id
    AND request.resource_type = 'booking'
    AND request.proposed_action IN ('booking.confirm', 'booking.amend', 'booking.cancel')
  FOR UPDATE;
  IF NOT FOUND
    OR v_request.resource_id <> v_booking.id
    OR v_request.status <> 'pending'
    OR (v_request.expires_at IS NOT NULL
      AND v_request.expires_at <= timezone('utc', now())) THEN
    RAISE EXCEPTION 'approval request is no longer actionable' USING ERRCODE = '22023';
  END IF;
  IF v_request.requester_membership_id = v_actor THEN
    RAISE EXCEPTION 'requester cannot approve their own booking change' USING ERRCODE = '42501';
  END IF;
  IF (v_request.proposed_action = 'booking.confirm' AND v_booking.status <> 'pending_approval')
    OR (v_request.proposed_action IN ('booking.amend', 'booking.cancel')
      AND v_booking.status NOT IN ('confirmed', 'checked_in')) THEN
    RAISE EXCEPTION 'booking is no longer in the required approval state' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.approval_decisions (
    organization_id, approval_request_id, approver_membership_id, decision, reason
  ) VALUES (
    p_organization_id, p_approval_request_id, v_actor, p_decision, btrim(p_reason)
  );
  UPDATE public.approval_requests
  SET status = p_decision, updated_at = timezone('utc', now())
  WHERE organization_id = p_organization_id AND id = p_approval_request_id;

  IF p_decision = 'rejected' AND v_request.proposed_action = 'booking.confirm' THEN
    UPDATE public.bookings
    SET status = 'draft'
    WHERE organization_id = p_organization_id AND id = v_request.resource_id;
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.approval.' || p_decision,
    'booking', v_request.resource_id, 'success', p_request_id,
    jsonb_build_object(
      'approval_request_id', p_approval_request_id,
      'proposed_action', v_request.proposed_action,
      'reason', btrim(p_reason)
    )
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'booking.approval.' || p_decision, 1,
    'booking-approval-decision:' || p_approval_request_id::text || ':' || p_decision,
    jsonb_build_object(
      'approval_request_id', p_approval_request_id,
      'booking_id', v_request.resource_id,
      'proposed_action', v_request.proposed_action
    )
  );
  RETURN true;
END;
$$;
