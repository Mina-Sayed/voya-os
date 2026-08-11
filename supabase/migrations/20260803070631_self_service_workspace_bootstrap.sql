-- Voya OS: verified-user self-service workspace bootstrap.
-- This is deliberately a narrow SECURITY DEFINER boundary: it never accepts
-- organization or role input and can only create the caller's own workspace.

CREATE OR REPLACE FUNCTION public.bootstrap_personal_workspace(p_request_id uuid DEFAULT NULL)
RETURNS TABLE (organization_id uuid, membership_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_email text := auth.email();
  v_organization_id uuid;
  v_membership_id uuid;
  v_organization_created boolean := false;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authenticated user required' USING ERRCODE = '42501';
  END IF;

  IF v_email IS NULL OR btrim(v_email) = '' THEN
    RAISE EXCEPTION 'verified email required' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.profiles (id, display_name, locale)
  VALUES (v_user_id, 'Voya Operator', 'ar')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.organizations (name, slug, default_locale, timezone, status)
  VALUES (
    'Voya Workspace',
    'workspace-' || replace(v_user_id::text, '-', ''),
    'ar',
    'Africa/Cairo',
    'active'
  )
  ON CONFLICT (slug) DO NOTHING
  RETURNING id INTO v_organization_id;

  v_organization_created := v_organization_id IS NOT NULL;

  IF NOT v_organization_created THEN
    SELECT organization.id
    INTO v_organization_id
    FROM public.organizations AS organization
    WHERE organization.slug = 'workspace-' || replace(v_user_id::text, '-', '')
    FOR UPDATE;
  END IF;

  IF v_organization_id IS NULL THEN
    RAISE EXCEPTION 'workspace bootstrap could not resolve organization' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
  VALUES (v_organization_id, v_user_id, 'owner', 'active')
  ON CONFLICT ON CONSTRAINT organization_memberships_organization_id_user_id_key DO NOTHING
  RETURNING id INTO v_membership_id;

  IF v_membership_id IS NULL THEN
    SELECT membership.id
    INTO v_membership_id
    FROM public.organization_memberships AS membership
    WHERE membership.organization_id = v_organization_id
      AND membership.user_id = v_user_id;
  END IF;

  IF v_membership_id IS NULL THEN
    RAISE EXCEPTION 'workspace bootstrap could not resolve membership' USING ERRCODE = 'P0001';
  END IF;

  IF v_organization_created THEN
    INSERT INTO public.audit_events (
      organization_id,
      actor_type,
      actor_membership_id,
      action,
      resource_type,
      resource_id,
      outcome,
      request_id,
      reason_code,
      after_delta
    )
    VALUES (
      v_organization_id,
      'user',
      v_membership_id,
      'organization.bootstrap',
      'organization',
      v_organization_id,
      'success',
      p_request_id,
      'self_service_verified_email',
      jsonb_build_object('source', 'self_service', 'role', 'owner')
    );
  END IF;

  RETURN QUERY SELECT v_organization_id, v_membership_id;
END;
$$;

REVOKE ALL ON FUNCTION public.bootstrap_personal_workspace(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bootstrap_personal_workspace(uuid) TO authenticated;

COMMENT ON FUNCTION public.bootstrap_personal_workspace(uuid)
IS 'Creates the authenticated user''s own private workspace exactly once after verified email sign-in.';
