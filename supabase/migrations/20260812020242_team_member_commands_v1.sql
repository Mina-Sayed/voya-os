-- Voya OS V1: owner-controlled team lifecycle with a database-enforced
-- last-owner invariant. Operator is the product role; existing operations
-- rows remain the compatibility representation until the catalog migration.

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
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'accountant', 'viewer') THEN
    RAISE EXCEPTION 'member read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT membership.id, membership.user_id, COALESCE(profile.display_name, membership.user_id::text),
    CASE membership.role WHEN 'operations' THEN 'operator' WHEN 'sales_agent' THEN 'operator' WHEN 'accountant' THEN 'viewer' ELSE membership.role END,
    membership.status, membership.created_at
  FROM public.organization_memberships AS membership
  LEFT JOIN public.profiles AS profile ON profile.id = membership.user_id
  WHERE membership.organization_id = p_organization_id
  ORDER BY (membership.role = 'owner') DESC, membership.created_at ASC, membership.id ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_organization_invitations(p_organization_id uuid)
RETURNS TABLE (
  id uuid, normalized_email text, role text, status text, expires_at timestamptz,
  created_at timestamptz, accepted_at timestamptz, delivery_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_role text;
BEGIN
  SELECT membership.role INTO v_role FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager') THEN RAISE EXCEPTION 'invitation read is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY SELECT invitation.id, invitation.normalized_email, invitation.role, invitation.status, invitation.expires_at, invitation.created_at, invitation.accepted_at, invitation.delivery_status
  FROM public.organization_invitations AS invitation WHERE invitation.organization_id = p_organization_id ORDER BY invitation.created_at DESC, invitation.id DESC;
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
DECLARE v_actor uuid; v_target public.organization_memberships%ROWTYPE; v_new_role text;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role = 'owner';
  IF v_actor IS NULL THEN RAISE EXCEPTION 'member role change is not permitted' USING ERRCODE = '42501'; END IF;
  v_new_role := lower(btrim(p_role));
  IF v_new_role NOT IN ('owner', 'manager', 'operator', 'viewer') THEN RAISE EXCEPTION 'member role is invalid' USING ERRCODE = '22023'; END IF;
  SELECT membership.* INTO v_target FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.id = p_membership_id FOR UPDATE;
  IF NOT FOUND OR v_target.status <> 'active' THEN RAISE EXCEPTION 'member is invalid' USING ERRCODE = '23503'; END IF;
  IF v_target.role = 'owner' AND v_new_role <> 'owner' AND (SELECT count(*) FROM public.organization_memberships WHERE organization_id = p_organization_id AND role = 'owner' AND status = 'active') <= 1 THEN
    RAISE EXCEPTION 'last active owner cannot be downgraded' USING ERRCODE = '42501';
  END IF;
  UPDATE public.organization_memberships SET role = CASE v_new_role WHEN 'operator' THEN 'operations' ELSE v_new_role END, updated_at = timezone('utc', now()) WHERE organization_id = p_organization_id AND id = p_membership_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, before_delta, after_delta)
  VALUES (p_organization_id, 'user', v_actor, 'member.role_changed', 'organization_membership', p_membership_id, 'success', p_request_id, jsonb_build_object('role', v_target.role), jsonb_build_object('role', v_new_role));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.suspend_organization_member(
  p_organization_id uuid, p_membership_id uuid, p_reason text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid; v_target public.organization_memberships%ROWTYPE;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role = 'owner';
  IF v_actor IS NULL THEN RAISE EXCEPTION 'member suspension is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'member suspension reason is required' USING ERRCODE = '22023'; END IF;
  SELECT membership.* INTO v_target FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.id = p_membership_id FOR UPDATE;
  IF NOT FOUND OR v_target.status <> 'active' THEN RAISE EXCEPTION 'member is invalid' USING ERRCODE = '23503'; END IF;
  IF v_target.role = 'owner' AND (SELECT count(*) FROM public.organization_memberships WHERE organization_id = p_organization_id AND role = 'owner' AND status = 'active') <= 1 THEN RAISE EXCEPTION 'last active owner cannot be suspended' USING ERRCODE = '42501'; END IF;
  UPDATE public.organization_memberships SET status = 'suspended', updated_at = timezone('utc', now()) WHERE organization_id = p_organization_id AND id = p_membership_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta) VALUES (p_organization_id, 'user', v_actor, 'member.suspended', 'organization_membership', p_membership_id, 'success', p_request_id, 'owner_action', jsonb_build_object('reason', btrim(p_reason)));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.reactivate_organization_member(
  p_organization_id uuid, p_membership_id uuid, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role = 'owner';
  IF v_actor IS NULL THEN RAISE EXCEPTION 'member reactivation is not permitted' USING ERRCODE = '42501'; END IF;
  UPDATE public.organization_memberships SET status = 'active', updated_at = timezone('utc', now()) WHERE organization_id = p_organization_id AND id = p_membership_id AND status = 'suspended';
  IF NOT FOUND THEN RAISE EXCEPTION 'suspended member is invalid' USING ERRCODE = '23503'; END IF;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id) VALUES (p_organization_id, 'user', v_actor, 'member.reactivated', 'organization_membership', p_membership_id, 'success', p_request_id);
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_organization_member(
  p_organization_id uuid, p_membership_id uuid, p_reason text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid; v_target public.organization_memberships%ROWTYPE;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role = 'owner';
  IF v_actor IS NULL THEN RAISE EXCEPTION 'member removal is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'member removal reason is required' USING ERRCODE = '22023'; END IF;
  SELECT membership.* INTO v_target FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.id = p_membership_id FOR UPDATE;
  IF NOT FOUND OR v_target.status = 'suspended' THEN RAISE EXCEPTION 'member is invalid' USING ERRCODE = '23503'; END IF;
  IF v_target.role = 'owner' AND (SELECT count(*) FROM public.organization_memberships WHERE organization_id = p_organization_id AND role = 'owner' AND status = 'active') <= 1 THEN RAISE EXCEPTION 'last active owner cannot be removed' USING ERRCODE = '42501'; END IF;
  UPDATE public.organization_memberships SET status = 'suspended', updated_at = timezone('utc', now()) WHERE organization_id = p_organization_id AND id = p_membership_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta) VALUES (p_organization_id, 'user', v_actor, 'member.removed', 'organization_membership', p_membership_id, 'success', p_request_id, 'owner_action', jsonb_build_object('reason', btrim(p_reason)));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_organization_invitation(
  p_organization_id uuid, p_invitation_id uuid, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role = 'owner';
  IF v_actor IS NULL THEN RAISE EXCEPTION 'invitation revoke is not permitted' USING ERRCODE = '42501'; END IF;
  UPDATE public.organization_invitations SET status = 'revoked', updated_at = timezone('utc', now()) WHERE organization_id = p_organization_id AND id = p_invitation_id AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'pending invitation is invalid' USING ERRCODE = '23503'; END IF;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id) VALUES (p_organization_id, 'user', v_actor, 'member.invitation_revoked', 'organization_invitation', p_invitation_id, 'success', p_request_id);
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.resend_organization_invitation(
  p_organization_id uuid, p_invitation_id uuid, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid;
BEGIN
  SELECT membership.id INTO v_actor FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role = 'owner';
  IF v_actor IS NULL THEN RAISE EXCEPTION 'invitation resend is not permitted' USING ERRCODE = '42501'; END IF;
  UPDATE public.organization_invitations SET expires_at = timezone('utc', now()) + interval '72 hours', delivery_status = 'pending', updated_at = timezone('utc', now()) WHERE organization_id = p_organization_id AND id = p_invitation_id AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'pending invitation is invalid' USING ERRCODE = '23503'; END IF;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id) VALUES (p_organization_id, 'user', v_actor, 'member.invitation_resent', 'organization_invitation', p_invitation_id, 'success', p_request_id);
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload) VALUES (p_organization_id, 'member.invitation.resent', 1, 'invitation-resend:' || p_invitation_id::text || ':' || extract(epoch FROM timezone('utc', now()))::bigint::text, jsonb_build_object('invitation_id', p_invitation_id));
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.list_organization_members(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_organization_invitations(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.change_organization_member_role(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.suspend_organization_member(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reactivate_organization_member(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.remove_organization_member(uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.revoke_organization_invitation(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resend_organization_invitation(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_organization_members(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_organization_invitations(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.change_organization_member_role(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.suspend_organization_member(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reactivate_organization_member(uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_organization_member(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_organization_invitation(uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resend_organization_invitation(uuid, uuid, uuid) TO authenticated;
