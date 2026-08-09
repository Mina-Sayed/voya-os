-- Voya OS: keep the booking approval function free of unused PL/pgSQL state.

CREATE OR REPLACE FUNCTION public.decide_booking_approval(
  p_organization_id uuid,
  p_approval_request_id uuid,
  p_decision text,
  p_reason text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
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
  SELECT request.* INTO v_request
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND request.id = p_approval_request_id
    AND request.resource_type = 'booking'
    AND request.proposed_action = 'booking.confirm'
  FOR UPDATE;
  IF NOT FOUND
    OR v_request.status <> 'pending'
    OR (v_request.expires_at IS NOT NULL AND v_request.expires_at <= timezone('utc', now())) THEN
    RAISE EXCEPTION 'approval request is no longer actionable' USING ERRCODE = '22023';
  END IF;
  IF v_request.requester_membership_id = v_actor THEN
    RAISE EXCEPTION 'requester cannot approve their own booking' USING ERRCODE = '42501';
  END IF;
  SELECT booking.* INTO v_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.id = v_request.resource_id
  FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'booking is no longer awaiting approval' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.approval_decisions (
    organization_id, approval_request_id, approver_membership_id, decision, reason
  ) VALUES (
    p_organization_id, p_approval_request_id, v_actor, p_decision, btrim(p_reason)
  );
  UPDATE public.approval_requests
  SET status = p_decision, updated_at = timezone('utc', now())
  WHERE organization_id = p_organization_id AND id = p_approval_request_id;
  IF p_decision = 'rejected' THEN
    UPDATE public.bookings
    SET status = 'draft'
    WHERE organization_id = p_organization_id AND id = v_request.resource_id;
  END IF;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'booking.approval.' || p_decision, 'booking',
    v_request.resource_id, 'success', p_request_id,
    jsonb_build_object('approval_request_id', p_approval_request_id, 'reason', btrim(p_reason))
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id,
    'booking.approval.' || p_decision,
    1,
    'booking-approval-decision:' || p_approval_request_id::text || ':' || p_decision,
    jsonb_build_object('approval_request_id', p_approval_request_id, 'booking_id', v_request.resource_id)
  );
  RETURN true;
END;
$$;

