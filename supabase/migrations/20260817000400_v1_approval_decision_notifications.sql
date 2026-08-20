-- Voya OS V1: notify the requester when an independent booking decision lands.
-- The trigger covers legacy and commercial booking approval RPCs without
-- duplicating command logic or exposing approval tables to browser roles.

CREATE OR REPLACE FUNCTION public.notify_booking_approval_decision()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_request public.approval_requests%ROWTYPE;
  v_title text;
  v_body text;
BEGIN
  SELECT request.* INTO v_request
  FROM public.approval_requests AS request
  WHERE request.organization_id = NEW.organization_id
    AND request.id = NEW.approval_request_id;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  v_title := CASE NEW.decision
    WHEN 'approved' THEN 'تم اعتماد طلب الحجز'
    ELSE 'تم رفض طلب الحجز'
  END;
  v_body := CASE v_request.proposed_action
    WHEN 'booking.confirm' THEN CASE NEW.decision WHEN 'approved' THEN 'تم اعتماد طلب تأكيد الحجز ويمكن استكمال دورة التأكيد.' ELSE 'تم رفض طلب تأكيد الحجز ويحتاج إلى مراجعة.' END
    WHEN 'booking.amend' THEN CASE NEW.decision WHEN 'approved' THEN 'تم اعتماد تعديل الحجز ويمكن استكمال التنفيذ.' ELSE 'تم رفض تعديل الحجز ويحتاج إلى مراجعة.' END
    WHEN 'booking.cancel' THEN CASE NEW.decision WHEN 'approved' THEN 'تم اعتماد طلب إلغاء الحجز ويمكن استكمال التنفيذ.' ELSE 'تم رفض طلب إلغاء الحجز.' END
    ELSE CASE NEW.decision WHEN 'approved' THEN 'تم اعتماد الطلب.' ELSE 'تم رفض الطلب.' END
  END;

  INSERT INTO public.notifications (
    organization_id, recipient_membership_id, category, title, body,
    resource_type, resource_id, dedupe_key
  ) VALUES (
    NEW.organization_id,
    v_request.requester_membership_id,
    'approval',
    v_title,
    v_body,
    v_request.resource_type,
    v_request.resource_id,
    'booking-approval-result:' || NEW.approval_request_id::text || ':' || NEW.decision
  ) ON CONFLICT (organization_id, dedupe_key) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS approval_decisions_notify_requester ON public.approval_decisions;
CREATE TRIGGER approval_decisions_notify_requester
  AFTER INSERT ON public.approval_decisions
  FOR EACH ROW EXECUTE FUNCTION public.notify_booking_approval_decision();

REVOKE ALL ON FUNCTION public.notify_booking_approval_decision() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.notify_booking_approval_decision() IS
  'Creates one tenant-scoped in-app decision result for the approval requester; external delivery remains separate.';
