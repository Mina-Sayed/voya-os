-- Voya OS: tenant-safe property ownership history and availability blocks.
-- Availability blocks remain separate from booking occupancy until a shared lock design is implemented.

CREATE TABLE public.property_owners (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) > 0),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, id)
);

CREATE TABLE public.property_ownership_periods (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  property_id uuid NOT NULL,
  property_owner_id uuid NOT NULL,
  start_date date NOT NULL,
  end_date date NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT property_ownership_period_valid_range CHECK (start_date < end_date),
  CONSTRAINT property_ownership_period_property_tenant_fk
    FOREIGN KEY (organization_id, property_id)
    REFERENCES public.properties (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT property_ownership_period_owner_tenant_fk
    FOREIGN KEY (organization_id, property_owner_id)
    REFERENCES public.property_owners (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT property_ownership_period_no_overlap
    EXCLUDE USING gist (
      organization_id WITH =,
      property_id WITH =,
      daterange(start_date, end_date, '[)') WITH &&
    )
);

CREATE TABLE public.availability_blocks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  property_id uuid NOT NULL,
  start_date date NOT NULL,
  end_date date NOT NULL,
  block_type text NOT NULL DEFAULT 'administrative'
    CHECK (block_type IN ('maintenance', 'owner_use', 'administrative')),
  reason text,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT availability_block_valid_range CHECK (start_date < end_date),
  CONSTRAINT availability_block_property_tenant_fk
    FOREIGN KEY (organization_id, property_id)
    REFERENCES public.properties (organization_id, id) ON DELETE RESTRICT
);

CREATE INDEX property_owners_organization_status_idx
  ON public.property_owners (organization_id, status, created_at DESC);
CREATE INDEX availability_blocks_property_dates_idx
  ON public.availability_blocks (organization_id, property_id, start_date, end_date);

CREATE TRIGGER property_owners_set_updated_at
  BEFORE UPDATE ON public.property_owners
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.property_owners ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.property_ownership_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.availability_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.property_owners FORCE ROW LEVEL SECURITY;
ALTER TABLE public.property_ownership_periods FORCE ROW LEVEL SECURITY;
ALTER TABLE public.availability_blocks FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.property_owners, public.property_ownership_periods, public.availability_blocks FROM PUBLIC;
