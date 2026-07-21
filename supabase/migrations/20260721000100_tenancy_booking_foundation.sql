-- Voya OS: tenancy and booking foundation.
-- Apply only through Supabase CLI / reviewed declarative migration workflows.

CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$;

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE RESTRICT,
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) > 0),
  locale text NOT NULL DEFAULT 'ar' CHECK (locale IN ('ar', 'en')),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE TABLE public.organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(btrim(name)) > 0),
  slug text NOT NULL UNIQUE CHECK (slug = lower(slug) AND slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  default_locale text NOT NULL DEFAULT 'ar' CHECK (default_locale IN ('ar', 'en')),
  timezone text NOT NULL DEFAULT 'Africa/Cairo' CHECK (char_length(btrim(timezone)) > 0),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended')),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE TABLE public.organization_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  role text NOT NULL CHECK (role IN ('owner', 'manager', 'sales_agent', 'operations', 'accountant', 'viewer')),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended')),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, user_id)
);

CREATE INDEX organization_memberships_active_user_idx
  ON public.organization_memberships (user_id, organization_id)
  WHERE status = 'active';

CREATE TABLE public.properties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  code text NOT NULL CHECK (char_length(btrim(code)) > 0),
  name text NOT NULL CHECK (char_length(btrim(name)) > 0),
  timezone text NOT NULL CHECK (char_length(btrim(timezone)) > 0),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, code)
);

CREATE TABLE public.clients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) > 0),
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, id)
);

CREATE TABLE public.bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  property_id uuid NOT NULL,
  client_id uuid,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending_approval', 'confirmed', 'cancelled', 'completed')),
  check_in date NOT NULL,
  check_out date NOT NULL,
  idempotency_key text,
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT bookings_valid_stay CHECK (check_in < check_out),
  CONSTRAINT bookings_property_in_organization_fk
    FOREIGN KEY (organization_id, property_id)
    REFERENCES public.properties (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT bookings_client_in_organization_fk
    FOREIGN KEY (organization_id, client_id)
    REFERENCES public.clients (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT bookings_idempotency_key_unique UNIQUE (organization_id, idempotency_key),
  CONSTRAINT bookings_no_confirmed_overlap
    EXCLUDE USING gist (
      organization_id WITH =,
      property_id WITH =,
      daterange(check_in, check_out, '[)') WITH &&
    ) WHERE (status = 'confirmed')
);

CREATE INDEX properties_organization_status_idx
  ON public.properties (organization_id, status, created_at DESC);
CREATE INDEX clients_organization_created_at_idx
  ON public.clients (organization_id, created_at DESC);
CREATE INDEX bookings_organization_status_check_in_idx
  ON public.bookings (organization_id, status, check_in);

CREATE OR REPLACE FUNCTION public.current_user_has_active_membership(target_organization_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.organization_memberships membership
    WHERE membership.organization_id = target_organization_id
      AND membership.user_id = auth.uid()
      AND membership.status = 'active'
  );
$$;

REVOKE ALL ON FUNCTION public.current_user_has_active_membership(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_has_active_membership(uuid) TO authenticated;

CREATE TRIGGER profiles_set_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER organizations_set_updated_at
  BEFORE UPDATE ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER memberships_set_updated_at
  BEFORE UPDATE ON public.organization_memberships
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER properties_set_updated_at
  BEFORE UPDATE ON public.properties
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER clients_set_updated_at
  BEFORE UPDATE ON public.clients
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER bookings_set_updated_at
  BEFORE UPDATE ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.properties ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.profiles FORCE ROW LEVEL SECURITY;
ALTER TABLE public.organizations FORCE ROW LEVEL SECURITY;
ALTER TABLE public.organization_memberships FORCE ROW LEVEL SECURITY;
ALTER TABLE public.properties FORCE ROW LEVEL SECURITY;
ALTER TABLE public.clients FORCE ROW LEVEL SECURITY;
ALTER TABLE public.bookings FORCE ROW LEVEL SECURITY;

CREATE POLICY profiles_read_own ON public.profiles
  FOR SELECT TO authenticated
  USING (id = auth.uid());

CREATE POLICY organizations_read_member ON public.organizations
  FOR SELECT TO authenticated
  USING (public.current_user_has_active_membership(id));

CREATE POLICY memberships_read_own ON public.organization_memberships
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY properties_read_member ON public.properties
  FOR SELECT TO authenticated
  USING (public.current_user_has_active_membership(organization_id));

CREATE POLICY clients_read_member ON public.clients
  FOR SELECT TO authenticated
  USING (public.current_user_has_active_membership(organization_id));

CREATE POLICY bookings_read_member ON public.bookings
  FOR SELECT TO authenticated
  USING (public.current_user_has_active_membership(organization_id));

REVOKE ALL ON TABLE public.profiles, public.organizations, public.organization_memberships,
  public.properties, public.clients, public.bookings FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON TABLE public.profiles, public.organizations, public.organization_memberships,
  public.properties, public.clients, public.bookings TO authenticated;
