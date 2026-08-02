-- Voya OS: booking approval and stay lifecycle commands.
-- No prices, deposits, refunds, commissions, or provider effects are inferred here.

CREATE TABLE public.booking_stay_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  booking_id uuid NOT NULL,
  event_type text NOT NULL CHECK (event_type IN ('check_in', 'check_out')),
  occurred_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  notes text CHECK (notes IS NULL OR char_length(btrim(notes)) BETWEEN 1 AND 2000),
  actor_membership_id uuid NOT NULL,
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT booking_stay_event_booking_fk FOREIGN KEY (organization_id, booking_id)
    REFERENCES public.bookings(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT booking_stay_event_actor_fk FOREIGN KEY (organization_id, actor_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT booking_stay_event_once UNIQUE (organization_id, booking_id, event_type),
  CONSTRAINT booking_stay_event_idempotency UNIQUE (organization_id, idempotency_key)
);

CREATE INDEX booking_stay_events_booking_idx ON public.booking_stay_events (organization_id, booking_id, event_type);
ALTER TABLE public.booking_stay_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.booking_stay_events FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.booking_stay_events FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.list_booking_work_queue(p_organization_id uuid)
RETURNS TABLE (
  id uuid,
  property_code text,
  property_name text,
  client_name text,
  status text,
  check_in date,
  check_out date,
  has_check_in boolean,
  has_check_out boolean,
  created_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_role text;
BEGIN
  SELECT membership.role INTO v_role FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'accountant') THEN
    RAISE EXCEPTION 'booking work queue read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT booking.id, property_record.code, property_record.name, client_record.display_name, booking.status,
         booking.check_in, booking.check_out,
         EXISTS (SELECT 1 FROM public.booking_stay_events AS stay_event WHERE stay_event.organization_id = booking.organization_id AND stay_event.booking_id = booking.id AND stay_event.event_type = 'check_in'),
         EXISTS (SELECT 1 FROM public.booking_stay_events AS stay_event WHERE stay_event.organization_id = booking.organization_id AND stay_event.booking_id = booking.id AND stay_event.event_type = 'check_out'),
         booking.created_at
  FROM public.bookings AS booking
  JOIN public.properties AS property_record ON property_record.organization_id = booking.organization_id AND property_record.id = booking.property_id
  LEFT JOIN public.clients AS client_record ON client_record.organization_id = booking.organization_id AND client_record.id = booking.client_id
  WHERE booking.organization_id = p_organization_id
  ORDER BY (booking.status IN ('completed', 'cancelled')), booking.check_in, booking.created_at DESC, booking.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.request_booking_approval(
  p_organization_id uuid,
  p_booking_id uuid,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_booking public.bookings%ROWTYPE; v_existing uuid; v_approval uuid; v_snapshot jsonb;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'booking approval request is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'booking approval idempotency key is invalid' USING ERRCODE = '22023'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503'; END IF;
  IF v_booking.status = 'pending_approval' THEN
    SELECT request.id INTO v_existing FROM public.approval_requests AS request WHERE request.organization_id = p_organization_id AND request.resource_type = 'booking' AND request.resource_id = p_booking_id AND request.proposed_action = 'booking.confirm' AND request.status = 'pending' ORDER BY request.created_at DESC LIMIT 1;
    IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  END IF;
  IF v_booking.status <> 'draft' THEN RAISE EXCEPTION 'booking cannot request approval in its current state' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.properties AS property_record WHERE property_record.organization_id = p_organization_id AND property_record.id = v_booking.property_id AND property_record.status = 'active') THEN RAISE EXCEPTION 'booking property is not active' USING ERRCODE = '23503'; END IF;
  v_snapshot := jsonb_build_object('booking_id', v_booking.id, 'property_id', v_booking.property_id, 'client_id', v_booking.client_id, 'check_in', v_booking.check_in, 'check_out', v_booking.check_out, 'status', 'draft');
  INSERT INTO public.approval_requests (organization_id, resource_type, resource_id, proposed_action, proposal_snapshot, snapshot_hash, requester_membership_id, expires_at)
  VALUES (p_organization_id, 'booking', p_booking_id, 'booking.confirm', v_snapshot, encode(public.digest(v_snapshot::text, 'sha256'), 'hex'), v_actor, timezone('utc', now()) + interval '24 hours')
  RETURNING id INTO v_approval;
  UPDATE public.bookings SET status = 'pending_approval' WHERE organization_id = p_organization_id AND id = p_booking_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'booking.approval_requested', 'booking', p_booking_id, 'success', p_request_id, jsonb_build_object('approval_request_id', v_approval));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'booking.approval.requested', 1, 'booking-approval:' || v_approval::text, jsonb_build_object('approval_request_id', v_approval, 'booking_id', p_booking_id));
  RETURN v_approval;
END;
$$;

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
DECLARE v_actor uuid; v_request public.approval_requests%ROWTYPE; v_booking public.bookings%ROWTYPE; v_approver_role text;
BEGIN
  SELECT membership.id, membership.role INTO v_actor, v_approver_role FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'booking approval decision is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') OR p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'approval decision is invalid' USING ERRCODE = '22023'; END IF;
  SELECT request.* INTO v_request FROM public.approval_requests AS request WHERE request.organization_id = p_organization_id AND request.id = p_approval_request_id AND request.resource_type = 'booking' AND request.proposed_action = 'booking.confirm' FOR UPDATE;
  IF NOT FOUND OR v_request.status <> 'pending' OR (v_request.expires_at IS NOT NULL AND v_request.expires_at <= timezone('utc', now())) THEN RAISE EXCEPTION 'approval request is no longer actionable' USING ERRCODE = '22023'; END IF;
  IF v_request.requester_membership_id = v_actor THEN RAISE EXCEPTION 'requester cannot approve their own booking' USING ERRCODE = '42501'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = v_request.resource_id FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'pending_approval' THEN RAISE EXCEPTION 'booking is no longer awaiting approval' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.approval_decisions (organization_id, approval_request_id, approver_membership_id, decision, reason)
  VALUES (p_organization_id, p_approval_request_id, v_actor, p_decision, btrim(p_reason));
  UPDATE public.approval_requests SET status = p_decision, updated_at = timezone('utc', now()) WHERE organization_id = p_organization_id AND id = p_approval_request_id;
  IF p_decision = 'rejected' THEN UPDATE public.bookings SET status = 'draft' WHERE organization_id = p_organization_id AND id = v_request.resource_id; END IF;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'booking.approval.' || p_decision, 'booking', v_request.resource_id, 'success', p_request_id, jsonb_build_object('approval_request_id', p_approval_request_id, 'reason', btrim(p_reason)));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'booking.approval.' || p_decision, 1, 'booking-approval-decision:' || p_approval_request_id::text || ':' || p_decision, jsonb_build_object('approval_request_id', p_approval_request_id, 'booking_id', v_request.resource_id));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_booking(
  p_organization_id uuid,
  p_booking_id uuid,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_booking public.bookings%ROWTYPE; v_approval public.approval_requests%ROWTYPE;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'booking confirmation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'booking confirmation idempotency key is invalid' USING ERRCODE = '22023'; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking is invalid' USING ERRCODE = '23503'; END IF;
  IF v_booking.status = 'confirmed' THEN RETURN true; END IF;
  IF v_booking.status <> 'pending_approval' THEN RAISE EXCEPTION 'booking is not awaiting confirmation' USING ERRCODE = '22023'; END IF;
  SELECT request.* INTO v_approval FROM public.approval_requests AS request WHERE request.organization_id = p_organization_id AND request.resource_type = 'booking' AND request.resource_id = p_booking_id AND request.proposed_action = 'booking.confirm' AND request.status = 'approved' ORDER BY request.created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking approval is required' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.properties AS property_record WHERE property_record.organization_id = p_organization_id AND property_record.id = v_booking.property_id AND property_record.status = 'active') THEN RAISE EXCEPTION 'booking property is not active' USING ERRCODE = '23503'; END IF;
  UPDATE public.bookings SET status = 'confirmed', idempotency_key = NULL WHERE organization_id = p_organization_id AND id = p_booking_id;
  UPDATE public.approval_requests SET status = 'executed', executed_at = timezone('utc', now()), updated_at = timezone('utc', now()) WHERE organization_id = p_organization_id AND id = v_approval.id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'booking.confirmed', 'booking', p_booking_id, 'success', p_request_id, jsonb_build_object('approval_request_id', v_approval.id));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'booking.confirmed', 1, 'booking-confirmed:' || p_booking_id::text, jsonb_build_object('booking_id', p_booking_id));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_booking_stay_event(
  p_organization_id uuid,
  p_booking_id uuid,
  p_event_type text,
  p_notes text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_booking public.bookings%ROWTYPE; v_existing public.booking_stay_events%ROWTYPE; v_event uuid;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'stay event is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_event_type IS NULL OR p_event_type NOT IN ('check_in', 'check_out') OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 OR (p_notes IS NOT NULL AND char_length(btrim(p_notes)) NOT BETWEEN 1 AND 2000) THEN RAISE EXCEPTION 'stay event input is invalid' USING ERRCODE = '22023'; END IF;
  SELECT stay_event.* INTO v_existing FROM public.booking_stay_events AS stay_event WHERE stay_event.organization_id = p_organization_id AND stay_event.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN RETURN v_existing.id; END IF;
  SELECT booking.* INTO v_booking FROM public.bookings AS booking WHERE booking.organization_id = p_organization_id AND booking.id = p_booking_id FOR UPDATE;
  IF NOT FOUND OR v_booking.status NOT IN ('confirmed') THEN RAISE EXCEPTION 'booking is not ready for a stay event' USING ERRCODE = '22023'; END IF;
  IF p_event_type = 'check_out' AND NOT EXISTS (SELECT 1 FROM public.booking_stay_events AS stay_event WHERE stay_event.organization_id = p_organization_id AND stay_event.booking_id = p_booking_id AND stay_event.event_type = 'check_in') THEN RAISE EXCEPTION 'check-in is required before check-out' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.booking_stay_events (organization_id, booking_id, event_type, notes, actor_membership_id, idempotency_key)
  VALUES (p_organization_id, p_booking_id, p_event_type, NULLIF(btrim(p_notes), ''), v_actor, btrim(p_idempotency_key)) RETURNING id INTO v_event;
  IF p_event_type = 'check_out' THEN UPDATE public.bookings SET status = 'completed' WHERE organization_id = p_organization_id AND id = p_booking_id; END IF;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'booking.' || p_event_type, 'booking', p_booking_id, 'success', p_request_id, jsonb_build_object('event_id', v_event, 'notes', NULLIF(btrim(p_notes), '')));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'booking.' || p_event_type, 1, 'booking-stay-event:' || v_event::text, jsonb_build_object('booking_id', p_booking_id, 'event_id', v_event));
  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.list_booking_work_queue(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_booking_approval(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.decide_booking_approval(uuid, uuid, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.confirm_booking(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_booking_stay_event(uuid, uuid, text, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_booking_work_queue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_booking_approval(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decide_booking_approval(uuid, uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_booking(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_booking_stay_event(uuid, uuid, text, text, text, uuid) TO authenticated;
