-- Voya OS V1: company-first onboarding and canonical team invitation boundary.
-- Existing membership role values remain readable during migration. New team
-- commands accept only OWNER/MANAGER/OPERATOR/VIEWER and map OPERATOR to the
-- existing operations capability internally until all command RPCs are
-- migrated to the canonical catalog.

ALTER TABLE public.organizations
  ADD COLUMN IF NOT EXISTS default_currency text NOT NULL DEFAULT 'EGP',
  ADD COLUMN IF NOT EXISTS onboarding_completed_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.organizations'::regclass
      AND conname = 'organizations_default_currency_check'
  ) THEN
    ALTER TABLE public.organizations
      ADD CONSTRAINT organizations_default_currency_check
      CHECK (default_currency ~ '^[A-Z]{3}$');
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.organization_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  normalized_email text NOT NULL CHECK (normalized_email = lower(btrim(normalized_email)) AND normalized_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  role text NOT NULL CHECK (role IN ('owner', 'manager', 'operator', 'viewer')),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'revoked', 'expired')),
  token_digest text NOT NULL CHECK (token_digest ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz NOT NULL,
  created_by_membership_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  accepted_at timestamptz,
  delivery_status text NOT NULL DEFAULT 'pending' CHECK (delivery_status IN ('pending', 'sent', 'failed')),
  CONSTRAINT organization_invitations_creator_fk
    FOREIGN KEY (organization_id, created_by_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS organization_invitations_one_pending_email_idx
  ON public.organization_invitations (organization_id, normalized_email)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS organization_invitations_token_idx
  ON public.organization_invitations (token_digest, status, expires_at);

ALTER TABLE public.organization_invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_invitations FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.organization_invitations FROM PUBLIC, anon, authenticated;

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
  IF EXISTS (
    SELECT 1 FROM public.organization_memberships
    WHERE user_id = v_user_id AND status = 'active'
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

CREATE OR REPLACE FUNCTION public.complete_organization_onboarding(
  p_organization_id uuid,
  p_name text,
  p_timezone text,
  p_default_currency text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_current_currency text;
BEGIN
  IF p_name IS NULL OR char_length(btrim(p_name)) NOT BETWEEN 2 AND 160
    OR p_timezone IS NULL OR char_length(btrim(p_timezone)) NOT BETWEEN 1 AND 80
    OR p_default_currency IS NULL OR p_default_currency !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'organization onboarding input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role = 'owner';
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'organization onboarding is not permitted' USING ERRCODE = '42501';
  END IF;
  SELECT organization.default_currency INTO v_current_currency
  FROM public.organizations AS organization
  WHERE organization.id = p_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'organization is invalid' USING ERRCODE = '23503';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.bookings
    WHERE organization_id = p_organization_id AND status = 'confirmed'
  ) AND p_default_currency <> v_current_currency THEN
    RAISE EXCEPTION 'organization currency is locked' USING ERRCODE = '22023';
  END IF;

  UPDATE public.organizations
  SET name = btrim(p_name), timezone = btrim(p_timezone), default_currency = p_default_currency,
      onboarding_completed_at = COALESCE(onboarding_completed_at, timezone('utc', now())),
      updated_at = timezone('utc', now())
  WHERE id = p_organization_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'organization.onboarding_completed',
    'organization', p_organization_id, 'success', p_request_id,
    jsonb_build_object('currency', p_default_currency)
  );
  RETURN true;
END
$$;

CREATE OR REPLACE FUNCTION public.invite_organization_member(
  p_organization_id uuid,
  p_email text,
  p_role text,
  p_token_digest text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_invitation_id uuid;
  v_email text := lower(btrim(p_email));
  v_role text := lower(btrim(p_role));
  v_token_digest text;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role = 'owner';
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'member invitation is not permitted' USING ERRCODE = '42501';
  END IF;
  IF v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    OR v_role NOT IN ('owner', 'manager', 'operator', 'viewer')
    OR p_token_digest IS NULL OR p_token_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invitation input is invalid' USING ERRCODE = '22023';
  END IF;
  -- The RPC receives the one-time raw token only from the trusted server
  -- action. Persist and index its SHA-256 digest; the raw token is carried
  -- only in the server-side outbox delivery payload.
  v_token_digest := encode(extensions.digest(p_token_digest, 'sha256'), 'hex');
  IF EXISTS (
    SELECT 1
    FROM public.organization_memberships AS membership
    JOIN auth.users AS account ON account.id = membership.user_id
    WHERE membership.organization_id = p_organization_id
      AND lower(account.email) = v_email
      AND membership.status = 'active'
  ) THEN
    RAISE EXCEPTION 'user is already a member' USING ERRCODE = '23505';
  END IF;
  UPDATE public.organization_invitations
  SET status = 'revoked', updated_at = timezone('utc', now())
  WHERE organization_id = p_organization_id AND normalized_email = v_email AND status = 'pending';

  INSERT INTO public.organization_invitations (
    organization_id, normalized_email, role, token_digest, expires_at,
    created_by_membership_id
  ) VALUES (
    p_organization_id, v_email, v_role, v_token_digest,
    timezone('utc', now()) + interval '72 hours', v_actor
  ) RETURNING id INTO v_invitation_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'member.invited', 'organization_invitation',
    v_invitation_id, 'success', p_request_id, jsonb_build_object('email', v_email, 'role', v_role)
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id,
    'organization.invitation.send_requested',
    1,
    'organization-invitation:' || v_invitation_id::text,
    jsonb_build_object(
      'invitation_id', v_invitation_id,
      'email', v_email,
      'role', v_role,
      'token', p_token_digest,
      'expires_at', timezone('utc', now()) + interval '72 hours'
    )
  );
  RETURN v_invitation_id;
END
$$;

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
  v_stored_role := CASE v_invitation.role WHEN 'operator' THEN 'operations' ELSE v_invitation.role END;
  INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
  VALUES (v_invitation.organization_id, v_user_id, v_stored_role, 'active')
  ON CONFLICT ON CONSTRAINT organization_memberships_organization_id_user_id_key DO UPDATE
    SET role = EXCLUDED.role, status = 'active', updated_at = timezone('utc', now())
  RETURNING id INTO v_membership_id;
  UPDATE public.organization_invitations
  SET status = 'accepted', accepted_at = timezone('utc', now())
  WHERE id = v_invitation.id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    v_invitation.organization_id, 'user', v_membership_id, 'member.invitation_accepted',
    'organization_invitation', v_invitation.id, 'success', p_request_id,
    jsonb_build_object('role', v_invitation.role)
  );
  RETURN QUERY SELECT v_invitation.organization_id, v_membership_id;
END
$$;

REVOKE ALL ON FUNCTION public.create_organization(text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.complete_organization_onboarding(uuid, text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.invite_organization_member(uuid, text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.accept_organization_invitation(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_organization(text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_organization_onboarding(uuid, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.invite_organization_member(uuid, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_organization_invitation(text, uuid) TO authenticated;
