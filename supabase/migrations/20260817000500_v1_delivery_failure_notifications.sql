-- Voya OS V1: surface terminal external-delivery failures to workspace owners.
-- Provider payloads remain private; the in-app notice contains only a safe
-- channel-neutral review message.

CREATE OR REPLACE FUNCTION public.notify_outbox_delivery_failure()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_title text;
  v_body text;
BEGIN
  IF OLD.state IS NOT DISTINCT FROM NEW.state
    OR NEW.state NOT IN ('dead_letter', 'needs_review')
    OR NEW.event_type NOT IN (
      'organization.invitation.send_requested',
      'member.invitation.resent',
      'whatsapp.message.send_requested'
    ) THEN
    RETURN NEW;
  END IF;

  v_title := CASE NEW.state
    WHEN 'dead_letter' THEN 'فشل تسليم خارجي'
    ELSE 'تسليم خارجي يحتاج مراجعة'
  END;
  v_body := CASE NEW.event_type
    WHEN 'whatsapp.message.send_requested' THEN 'تعذر تسليم رسالة WhatsApp خارجية. راجع الحالة من صندوق WhatsApp قبل إعادة المحاولة.'
    ELSE 'تعذر تسليم دعوة عضو بالبريد. راجع حالة الدعوة قبل إعادة الإرسال.'
  END;

  INSERT INTO public.notifications (
    organization_id, recipient_membership_id, category, title, body,
    resource_type, resource_id, dedupe_key
  )
  SELECT NEW.organization_id,
    membership.id,
    'system',
    v_title,
    v_body,
    'outbox_event',
    NEW.id,
    'outbox-delivery-failure:' || NEW.id::text || ':' || NEW.state || ':' || coalesce(NEW.last_error_code, 'unknown') || ':' || membership.id::text
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = NEW.organization_id
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager')
  ON CONFLICT (organization_id, dedupe_key) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS outbox_delivery_failure_notification ON public.outbox_events;
CREATE TRIGGER outbox_delivery_failure_notification
  AFTER UPDATE OF state ON public.outbox_events
  FOR EACH ROW EXECUTE FUNCTION public.notify_outbox_delivery_failure();

REVOKE ALL ON FUNCTION public.notify_outbox_delivery_failure() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.notify_outbox_delivery_failure() IS
  'Creates safe owner/manager review notices for terminal email or WhatsApp delivery failures.';
