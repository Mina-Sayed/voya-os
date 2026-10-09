-- A pending invitation cannot restore permissions revoked after it was issued.
-- Serialize acceptance with member role/status changes using one organization
-- advisory lock, and keep the existing AAL2 public action boundaries.

CREATE OR REPLACE FUNCTION public.accept_organization_invitation(
  p_token_digest text,
  p_request_id uuid DEFAULT NULL
)
RETURNS TABLE (organization_id uuid, membership_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_email text := lower(btrim(auth.email()));
  v_invitation public.organization_invitations%ROWTYPE;
  v_existing_membership public.organization_memberships%ROWTYPE;
  v_membership_id uuid;
  v_stored_role text;
  v_effective_role text;
BEGIN
  IF v_user_id IS NULL OR v_email IS NULL OR p_token_digest IS NULL OR p_token_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invitation acceptance is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT invitation.* INTO v_invitation
  FROM public.organization_invitations AS invitation
  WHERE invitation.token_digest = encode(extensions.digest(p_token_digest, 'sha256'), 'hex')
    AND invitation.status = 'pending'
    AND invitation.expires_at > timezone('utc', now())
    AND invitation.normalized_email = v_email
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invitation is invalid or expired' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_invitation.organization_id::text, 1)
  );

  SELECT membership.* INTO v_existing_membership
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = v_invitation.organization_id
    AND membership.user_id = v_user_id
  FOR UPDATE;
  IF FOUND AND v_existing_membership.status = 'suspended'
    AND v_invitation.created_at <= v_existing_membership.updated_at THEN
    RAISE EXCEPTION 'invitation is invalid or expired' USING ERRCODE = '42501';
  END IF;

  v_stored_role := CASE v_invitation.role WHEN 'operator' THEN 'operations' ELSE v_invitation.role END;
  INSERT INTO public.organization_memberships AS current_membership (
    organization_id, user_id, role, status
  )
  VALUES (v_invitation.organization_id, v_user_id, v_stored_role, 'active')
  ON CONFLICT ON CONSTRAINT organization_memberships_organization_id_user_id_key DO UPDATE
    SET role = CASE
          WHEN current_membership.status = 'active' THEN current_membership.role
          ELSE EXCLUDED.role
        END,
        status = 'active',
        updated_at = timezone('utc', now())
  RETURNING current_membership.id, current_membership.role
  INTO v_membership_id, v_effective_role;

  UPDATE public.organization_invitations
  SET status = 'accepted', accepted_at = timezone('utc', now())
  WHERE id = v_invitation.id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    v_invitation.organization_id, 'user', v_membership_id, 'member.invitation_accepted',
    'organization_invitation', v_invitation.id, 'success', p_request_id,
    jsonb_build_object('role', v_effective_role, 'invited_role', v_invitation.role)
  );
  RETURN QUERY SELECT v_invitation.organization_id, v_membership_id;
END
$$;

REVOKE ALL ON FUNCTION public.accept_organization_invitation(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_organization_invitation(text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.change_organization_member_role(
  p_organization_id uuid,
  p_membership_id uuid,
  p_role text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_organization_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id
      AND membership.user_id = auth.uid() AND membership.status = 'active'
      AND membership.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'member role change is not permitted' USING ERRCODE = '42501';
  END IF;
  -- Match invitation acceptance's organization-before-membership lock order.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text, 1)
  );
  RETURN public.change_organization_member_role_without_workspace_aal2(
    p_organization_id, p_membership_id, p_role, p_request_id
  );
END
$$;

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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_organization_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id
      AND membership.user_id = auth.uid() AND membership.status = 'active'
      AND membership.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'member suspension is not permitted' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text, 1)
  );
  RETURN public.suspend_organization_member_without_workspace_aal2(
    p_organization_id, p_membership_id, p_reason, p_request_id
  );
END
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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_organization_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id
      AND membership.user_id = auth.uid() AND membership.status = 'active'
      AND membership.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'member removal is not permitted' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text, 1)
  );
  RETURN public.remove_organization_member_without_workspace_aal2(
    p_organization_id, p_membership_id, p_reason, p_request_id
  );
END
$$;

CREATE OR REPLACE FUNCTION public.reactivate_organization_member(
  p_organization_id uuid,
  p_membership_id uuid,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_organization_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id
      AND membership.user_id = auth.uid() AND membership.status = 'active'
      AND membership.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'member reactivation is not permitted' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text, 1)
  );
  RETURN public.reactivate_organization_member_without_workspace_aal2(
    p_organization_id, p_membership_id, p_request_id
  );
END
$$;

REVOKE ALL ON FUNCTION public.change_organization_member_role(uuid, uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.suspend_organization_member(uuid, uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.remove_organization_member(uuid, uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reactivate_organization_member(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.change_organization_member_role(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.suspend_organization_member(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_organization_member(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reactivate_organization_member(uuid, uuid, uuid) TO authenticated;
