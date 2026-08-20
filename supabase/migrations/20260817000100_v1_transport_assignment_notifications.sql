-- Voya OS V1: transport assignment is an in-app operational notification.
-- The notification is emitted by the database transaction so a successful
-- assignment cannot be observed without its corresponding recipient notice.

CREATE OR REPLACE FUNCTION public.notify_transport_assignment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.status = 'assigned'
    AND NEW.created_by_membership_id IS NOT NULL
    AND (
      OLD.status IS DISTINCT FROM NEW.status
      OR OLD.vehicle_id IS DISTINCT FROM NEW.vehicle_id
      OR OLD.driver_id IS DISTINCT FROM NEW.driver_id
    ) THEN
    INSERT INTO public.notifications (
      organization_id,
      recipient_membership_id,
      category,
      title,
      body,
      resource_type,
      resource_id,
      dedupe_key
    ) VALUES (
      NEW.organization_id,
      NEW.created_by_membership_id,
      'operational',
      'تم إسناد طلب نقل',
      'تم إسناد طلب النقل "' || btrim(NEW.guest_label) || '" للمراجعة والتنفيذ.',
      'transport_request',
      NEW.id,
      'transport-request-assigned:' || NEW.id::text || ':' || extensions.gen_random_uuid()::text
    ) ON CONFLICT (organization_id, dedupe_key) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS transport_requests_notify_assignment ON public.transport_requests;
CREATE TRIGGER transport_requests_notify_assignment
  AFTER UPDATE OF vehicle_id, driver_id, status ON public.transport_requests
  FOR EACH ROW EXECUTE FUNCTION public.notify_transport_assignment();

REVOKE ALL ON FUNCTION public.notify_transport_assignment() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.notify_transport_assignment() IS
  'Creates one tenant-scoped in-app notification for each new transport assignment; provider delivery is separate.';
