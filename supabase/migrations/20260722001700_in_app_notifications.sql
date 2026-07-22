-- Voya OS: logical in-app notification facts. Provider delivery remains separate.

CREATE TABLE public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  recipient_membership_id uuid NOT NULL,
  category text NOT NULL CHECK (category IN ('operational', 'approval', 'finance', 'security', 'system')),
  title text NOT NULL CHECK (char_length(btrim(title)) > 0),
  body text NOT NULL CHECK (char_length(btrim(body)) > 0),
  resource_type text,
  resource_id uuid,
  dedupe_key text NOT NULL CHECK (char_length(btrim(dedupe_key)) > 0),
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT notifications_recipient_tenant_fk FOREIGN KEY (organization_id, recipient_membership_id)
    REFERENCES public.organization_memberships (organization_id, id) ON DELETE RESTRICT,
  UNIQUE (organization_id, dedupe_key)
);
CREATE INDEX notifications_unread_recipient_idx ON public.notifications (organization_id, recipient_membership_id, created_at DESC) WHERE read_at IS NULL;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.notifications FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.list_my_notifications(p_organization_id uuid, p_limit integer DEFAULT 50)
RETURNS TABLE (id uuid, category text, title text, body text, resource_type text, resource_id uuid, read_at timestamptz, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_membership_id uuid;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN RAISE EXCEPTION 'notification limit is invalid' USING ERRCODE = '22023'; END IF;
  SELECT membership.id INTO v_membership_id FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_membership_id IS NULL THEN RAISE EXCEPTION 'notification read is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY SELECT notification.id, notification.category, notification.title, notification.body, notification.resource_type, notification.resource_id, notification.read_at, notification.created_at
  FROM public.notifications AS notification WHERE notification.organization_id = p_organization_id AND notification.recipient_membership_id = v_membership_id
  ORDER BY notification.created_at DESC, notification.id DESC LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_notification_read(p_organization_id uuid, p_notification_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_membership_id uuid; v_updated boolean;
BEGIN
  SELECT membership.id INTO v_membership_id FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_membership_id IS NULL THEN RAISE EXCEPTION 'notification read is not permitted' USING ERRCODE = '42501'; END IF;
  UPDATE public.notifications SET read_at = timezone('utc', now())
  WHERE id = p_notification_id AND organization_id = p_organization_id AND recipient_membership_id = v_membership_id AND read_at IS NULL;
  v_updated := FOUND;
  IF v_updated THEN
    INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome)
    VALUES (p_organization_id, 'user', v_membership_id, 'notification.read', 'notification', p_notification_id, 'success');
  END IF;
  RETURN v_updated;
END;
$$;

REVOKE ALL ON FUNCTION public.list_my_notifications(uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_notification_read(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_notifications(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_notification_read(uuid, uuid) TO authenticated;
