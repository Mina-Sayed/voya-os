-- R05: a pending invitation is a snapshot of the requested role, not
-- authority to overwrite a member's later active role. Serialize acceptance
-- with owner role changes using the same per-organization advisory key.
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

  -- Use the same organization lock as owner role/suspension/removal changes.
  -- The upsert also preserves any role already held by an active membership.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_invitation.organization_id::text, 1)
  );

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

-- R18: self-service organization creation is available only to a user with no
-- membership history. Keep the per-user advisory lock ahead of this check so
-- concurrent create attempts cannot both pass it.
CREATE OR REPLACE FUNCTION public.create_organization(
  p_name text,
  p_timezone text DEFAULT 'Africa/Cairo',
  p_default_currency text DEFAULT 'EGP',
  p_request_id uuid DEFAULT NULL
)
RETURNS TABLE (organization_id uuid, membership_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_email text := auth.email();
  v_organization_id uuid;
  v_membership_id uuid;
  v_slug text;
BEGIN
  IF v_user_id IS NULL OR v_email IS NULL OR btrim(v_email) = '' THEN
    RAISE EXCEPTION 'verified user required' USING ERRCODE = '42501';
  END IF;
  IF p_name IS NULL OR char_length(btrim(p_name)) NOT BETWEEN 2 AND 160
    OR p_timezone IS NULL OR char_length(btrim(p_timezone)) NOT BETWEEN 1 AND 80
    OR p_default_currency IS NULL OR p_default_currency !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'organization onboarding input is invalid' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user_id::text, 0));

  IF EXISTS (
    SELECT 1 FROM public.organization_memberships
    WHERE user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'user already belongs to an organization' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.profiles (id, display_name, locale)
  VALUES (v_user_id, COALESCE(NULLIF(btrim(split_part(v_email, '@', 1)), ''), 'Voya Operator'), 'ar')
  ON CONFLICT (id) DO NOTHING;

  v_slug := 'org-' || replace(gen_random_uuid()::text, '-', '');
  INSERT INTO public.organizations (name, slug, default_locale, timezone, default_currency, status, onboarding_completed_at)
  VALUES (btrim(p_name), v_slug, 'ar', btrim(p_timezone), p_default_currency, 'active', timezone('utc', now()))
  RETURNING id INTO v_organization_id;

  INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
  VALUES (v_organization_id, v_user_id, 'owner', 'active')
  RETURNING id INTO v_membership_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, reason_code, after_delta
  ) VALUES (
    v_organization_id, 'user', v_membership_id, 'organization.created',
    'organization', v_organization_id, 'success', p_request_id,
    'company_first_onboarding', jsonb_build_object('role', 'owner', 'currency', p_default_currency)
  );

  RETURN QUERY SELECT v_organization_id, v_membership_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_organization(text, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_organization(text, text, text, uuid) TO authenticated;
