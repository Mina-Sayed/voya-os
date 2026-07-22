-- Voya OS: one database-enforced occupancy ledger for bookings and blocks.
-- This migration deliberately adds no browser write grants or business-policy
-- approval logic. Future commands must use this protected invariant.

ALTER TABLE public.bookings
  ADD CONSTRAINT bookings_organization_id_id_unique UNIQUE (organization_id, id);

ALTER TABLE public.availability_blocks
  ADD CONSTRAINT availability_blocks_organization_id_id_unique UNIQUE (organization_id, id);

CREATE TABLE public.property_occupancies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  property_id uuid NOT NULL,
  booking_id uuid,
  availability_block_id uuid,
  start_date date NOT NULL,
  end_date date NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT property_occupancy_valid_range CHECK (start_date < end_date),
  CONSTRAINT property_occupancy_one_source CHECK (
    num_nonnulls(booking_id, availability_block_id) = 1
  ),
  CONSTRAINT property_occupancy_property_tenant_fk
    FOREIGN KEY (organization_id, property_id)
    REFERENCES public.properties (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT property_occupancy_booking_tenant_fk
    FOREIGN KEY (organization_id, booking_id)
    REFERENCES public.bookings (organization_id, id) ON DELETE CASCADE,
  CONSTRAINT property_occupancy_block_tenant_fk
    FOREIGN KEY (organization_id, availability_block_id)
    REFERENCES public.availability_blocks (organization_id, id) ON DELETE CASCADE,
  CONSTRAINT property_occupancy_booking_unique UNIQUE (booking_id),
  CONSTRAINT property_occupancy_block_unique UNIQUE (availability_block_id),
  CONSTRAINT property_occupancy_no_overlap
    EXCLUDE USING gist (
      organization_id WITH =,
      property_id WITH =,
      daterange(start_date, end_date, '[)') WITH &&
    )
);

INSERT INTO public.property_occupancies (
  organization_id, property_id, booking_id, start_date, end_date
)
SELECT organization_id, property_id, id, check_in, check_out
FROM public.bookings
WHERE status = 'confirmed';

INSERT INTO public.property_occupancies (
  organization_id, property_id, availability_block_id, start_date, end_date
)
SELECT organization_id, property_id, id, start_date, end_date
FROM public.availability_blocks;

CREATE OR REPLACE FUNCTION public.sync_booking_occupancy()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $$
BEGIN
  DELETE FROM public.property_occupancies
  WHERE booking_id = NEW.id;

  IF NEW.status = 'confirmed' THEN
    INSERT INTO public.property_occupancies (
      organization_id, property_id, booking_id, start_date, end_date
    ) VALUES (
      NEW.organization_id, NEW.property_id, NEW.id, NEW.check_in, NEW.check_out
    );
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_availability_block_occupancy()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $$
BEGIN
  DELETE FROM public.property_occupancies
  WHERE availability_block_id = NEW.id;

  INSERT INTO public.property_occupancies (
    organization_id, property_id, availability_block_id, start_date, end_date
  ) VALUES (
    NEW.organization_id, NEW.property_id, NEW.id, NEW.start_date, NEW.end_date
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER bookings_sync_property_occupancy
  AFTER INSERT OR UPDATE OF organization_id, property_id, status, check_in, check_out
  ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.sync_booking_occupancy();

CREATE TRIGGER availability_blocks_sync_property_occupancy
  AFTER INSERT OR UPDATE OF organization_id, property_id, start_date, end_date
  ON public.availability_blocks
  FOR EACH ROW EXECUTE FUNCTION public.sync_availability_block_occupancy();

ALTER TABLE public.property_occupancies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.property_occupancies FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.property_occupancies FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_booking_occupancy() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_availability_block_occupancy() FROM PUBLIC;
