-- VOYA Stay V1 public projection and request-only guest intake.
-- Only explicitly approved derivatives enter the public media bucket;
-- original property-images remain private.

CREATE TABLE public.voya_stay_storefront_config (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  organization_id uuid UNIQUE REFERENCES public.organizations (id) ON DELETE RESTRICT,
  storefront_enabled boolean NOT NULL DEFAULT false,
  requests_enabled boolean NOT NULL DEFAULT false,
  privacy_notice_url text,
  privacy_notice_version text,
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT voya_stay_storefront_requires_organization
    CHECK (NOT storefront_enabled OR organization_id IS NOT NULL),
  CONSTRAINT voya_stay_requests_require_privacy_notice
    CHECK (NOT requests_enabled OR (
      storefront_enabled
      AND organization_id IS NOT NULL
      AND privacy_notice_url ~ '^https://[^[:space:]]+$'
      AND privacy_notice_version ~ '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$'
    ))
);

INSERT INTO public.voya_stay_storefront_config (singleton)
VALUES (true);

CREATE TABLE public.voya_stay_public_listings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  property_id uuid NOT NULL,
  slug text NOT NULL CHECK (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' AND char_length(slug) BETWEEN 3 AND 80),
  title text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 120),
  description text NOT NULL CHECK (char_length(btrim(description)) BETWEEN 1 AND 2500),
  area_label text NOT NULL CHECK (char_length(btrim(area_label)) BETWEEN 1 AND 100),
  bedrooms integer NOT NULL CHECK (bedrooms BETWEEN 0 AND 100),
  max_guests integer NOT NULL CHECK (max_guests BETWEEN 1 AND 50),
  amenities text[] NOT NULL DEFAULT ARRAY[]::text[],
  status text NOT NULL DEFAULT 'unpublished' CHECK (status IN ('published', 'unpublished')),
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  published_at timestamptz,
  created_by_membership_id uuid NOT NULL,
  updated_by_membership_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, property_id),
  UNIQUE (organization_id, slug),
  CONSTRAINT voya_stay_public_listing_property_tenant_fk
    FOREIGN KEY (organization_id, property_id)
    REFERENCES public.properties (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT voya_stay_public_listing_creator_tenant_fk
    FOREIGN KEY (organization_id, created_by_membership_id)
    REFERENCES public.organization_memberships (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT voya_stay_public_listing_updater_tenant_fk
    FOREIGN KEY (organization_id, updated_by_membership_id)
    REFERENCES public.organization_memberships (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT voya_stay_public_listing_amenities_valid
    CHECK (cardinality(amenities) <= 20 AND array_position(amenities, '') IS NULL),
  CONSTRAINT voya_stay_public_listing_published_at_consistent
    CHECK ((status = 'published') = (published_at IS NOT NULL))
);

ALTER TABLE public.property_images
  ADD CONSTRAINT property_images_organization_property_id_unique
    UNIQUE (organization_id, property_id, id);

CREATE TABLE public.voya_stay_public_listing_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  listing_id uuid NOT NULL,
  property_id uuid NOT NULL,
  source_image_id uuid NOT NULL,
  storage_path text NOT NULL CHECK (storage_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]webp$'),
  position integer NOT NULL CHECK (position BETWEEN 0 AND 11),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, listing_id, id),
  UNIQUE (organization_id, listing_id, source_image_id),
  UNIQUE (storage_path),
  UNIQUE (organization_id, listing_id, position),
  CONSTRAINT voya_stay_public_listing_image_listing_tenant_fk
    FOREIGN KEY (organization_id, listing_id)
    REFERENCES public.voya_stay_public_listings (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT voya_stay_public_listing_image_source_tenant_fk
    FOREIGN KEY (organization_id, property_id, source_image_id)
    REFERENCES public.property_images (organization_id, property_id, id) ON DELETE RESTRICT
);

CREATE TABLE public.voya_stay_publication_commands (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  command text NOT NULL CHECK (command IN ('publish', 'unpublish')),
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
  listing_id uuid NOT NULL,
  actor_membership_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, command, idempotency_key),
  CONSTRAINT voya_stay_publication_command_listing_tenant_fk
    FOREIGN KEY (organization_id, listing_id)
    REFERENCES public.voya_stay_public_listings (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT voya_stay_publication_command_actor_tenant_fk
    FOREIGN KEY (organization_id, actor_membership_id)
    REFERENCES public.organization_memberships (organization_id, id) ON DELETE RESTRICT
);

CREATE TABLE public.voya_stay_public_media_cleanup (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  listing_id uuid NOT NULL,
  storage_path text NOT NULL CHECK (storage_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]webp$'),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (storage_path),
  CONSTRAINT voya_stay_media_cleanup_listing_tenant_fk
    FOREIGN KEY (organization_id, listing_id)
    REFERENCES public.voya_stay_public_listings (organization_id, id) ON DELETE RESTRICT
);

CREATE INDEX voya_stay_media_cleanup_listing_created_idx
  ON public.voya_stay_public_media_cleanup (organization_id, listing_id, created_at);

CREATE OR REPLACE FUNCTION public.hide_voya_stay_listings_when_property_inactive_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_listing public.voya_stay_public_listings%ROWTYPE;
  v_new_version integer;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = NEW.organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
  ORDER BY membership.id
  LIMIT 1;

  FOR v_listing IN
    SELECT listing.*
    FROM public.voya_stay_public_listings AS listing
    WHERE listing.organization_id = NEW.organization_id
      AND listing.property_id = NEW.id
      AND listing.status = 'published'
    FOR UPDATE
  LOOP
    INSERT INTO public.voya_stay_public_media_cleanup (organization_id, listing_id, storage_path)
    SELECT image.organization_id, image.listing_id, image.storage_path
    FROM public.voya_stay_public_listing_images AS image
    WHERE image.organization_id = NEW.organization_id AND image.listing_id = v_listing.id
    ON CONFLICT (storage_path) DO NOTHING;
    DELETE FROM public.voya_stay_public_listing_images
    WHERE organization_id = NEW.organization_id AND listing_id = v_listing.id;

    UPDATE public.voya_stay_public_listings AS listing
    SET status = 'unpublished',
        published_at = NULL,
        version = listing.version + 1,
        updated_by_membership_id = coalesce(v_actor, listing.updated_by_membership_id),
        updated_at = timezone('utc', now())
    WHERE listing.organization_id = NEW.organization_id AND listing.id = v_listing.id
    RETURNING version INTO v_new_version;

    INSERT INTO public.audit_events (
      organization_id, actor_type, actor_membership_id, action, resource_type,
      resource_id, outcome, request_id, before_delta, after_delta
    ) VALUES (
      NEW.organization_id,
      CASE WHEN v_actor IS NULL THEN 'system' ELSE 'user' END,
      v_actor,
      'voya_stay.listing.unpublished',
      'voya_stay_public_listing',
      v_listing.id,
      'success',
      gen_random_uuid(),
      jsonb_build_object('status', 'published', 'version', v_listing.version),
      jsonb_build_object('status', 'unpublished', 'version', v_new_version, 'reason', 'property_inactive')
    );
    INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
    VALUES (
      NEW.organization_id,
      'voya_stay.listing.unpublished',
      1,
      'voya-stay-listing-unpublished:' || v_listing.id::text || ':' || v_new_version::text,
      jsonb_build_object('listing_id', v_listing.id, 'reason', 'property_inactive')
    );
  END LOOP;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.hide_voya_stay_listings_when_property_inactive_v1() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER properties_hide_voya_stay_public_listing_when_inactive
  AFTER UPDATE OF status ON public.properties
  FOR EACH ROW
  WHEN (OLD.status = 'active' AND NEW.status <> 'active')
  EXECUTE FUNCTION public.hide_voya_stay_listings_when_property_inactive_v1();

CREATE TABLE public.voya_stay_request_rate_limits (
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE CASCADE,
  fingerprint text NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
  bucket_start timestamptz NOT NULL,
  attempts integer NOT NULL CHECK (attempts BETWEEN 1 AND 5),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (organization_id, fingerprint, bucket_start)
);

CREATE TABLE public.voya_stay_guest_request_idempotency (
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  idempotency_key text NOT NULL CHECK (idempotency_key ~ '^[0-9a-f-]{36}$'),
  payload_fingerprint text NOT NULL CHECK (payload_fingerprint ~ '^[0-9a-f]{64}$'),
  lead_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (organization_id, idempotency_key),
  CONSTRAINT voya_stay_guest_request_lead_tenant_fk
    FOREIGN KEY (organization_id, lead_id)
    REFERENCES public.leads (organization_id, id) ON DELETE RESTRICT
);

ALTER TABLE public.leads
  ADD COLUMN requested_property_id uuid,
  ADD COLUMN requested_property_title text,
  ADD COLUMN contact_consent_version text,
  ADD COLUMN contact_consented_at timestamptz,
  ADD CONSTRAINT leads_requested_property_tenant_fk
    FOREIGN KEY (organization_id, requested_property_id)
    REFERENCES public.properties (organization_id, id) ON DELETE RESTRICT,
  ADD CONSTRAINT leads_requested_property_snapshot_consistent
    CHECK ((requested_property_id IS NULL) = (requested_property_title IS NULL)),
  ADD CONSTRAINT leads_contact_consent_consistent
    CHECK ((contact_consent_version IS NULL) = (contact_consented_at IS NULL));

CREATE INDEX leads_voya_stay_requested_property_idx
  ON public.leads (organization_id, requested_property_id, created_at DESC)
  WHERE requested_property_id IS NOT NULL;

ALTER TABLE public.voya_stay_storefront_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_public_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_public_listing_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_publication_commands ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_public_media_cleanup ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_request_rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_guest_request_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_storefront_config FORCE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_public_listings FORCE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_public_listing_images FORCE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_publication_commands FORCE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_public_media_cleanup FORCE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_request_rate_limits FORCE ROW LEVEL SECURITY;
ALTER TABLE public.voya_stay_guest_request_idempotency FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.voya_stay_storefront_config,
  public.voya_stay_public_listings,
  public.voya_stay_public_listing_images,
  public.voya_stay_publication_commands,
  public.voya_stay_public_media_cleanup,
  public.voya_stay_request_rate_limits,
  public.voya_stay_guest_request_idempotency
  FROM PUBLIC, anon, authenticated, service_role;

DO $$
BEGIN
  IF to_regclass('storage.buckets') IS NOT NULL THEN
    EXECUTE $storage$
      INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
      VALUES ('voya-stay-public-media', 'voya-stay-public-media', true, 8388608, ARRAY['image/webp']::text[])
      ON CONFLICT (id) DO UPDATE
        SET name = EXCLUDED.name,
            public = true,
            file_size_limit = EXCLUDED.file_size_limit,
            allowed_mime_types = EXCLUDED.allowed_mime_types
    $storage$;
  END IF;
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS voya_stay_public_media_no_browser_insert ON storage.objects';
    EXECUTE 'DROP POLICY IF EXISTS voya_stay_public_media_no_browser_update ON storage.objects';
    EXECUTE 'DROP POLICY IF EXISTS voya_stay_public_media_no_browser_delete ON storage.objects';
    EXECUTE $policy$
      CREATE POLICY voya_stay_public_media_no_browser_insert
      ON storage.objects AS RESTRICTIVE FOR INSERT TO anon, authenticated
      WITH CHECK (bucket_id <> 'voya-stay-public-media')
    $policy$;
    EXECUTE $policy$
      CREATE POLICY voya_stay_public_media_no_browser_update
      ON storage.objects AS RESTRICTIVE FOR UPDATE TO anon, authenticated
      USING (bucket_id <> 'voya-stay-public-media')
      WITH CHECK (bucket_id <> 'voya-stay-public-media')
    $policy$;
    EXECUTE $policy$
      CREATE POLICY voya_stay_public_media_no_browser_delete
      ON storage.objects AS RESTRICTIVE FOR DELETE TO anon, authenticated
      USING (bucket_id <> 'voya-stay-public-media')
    $policy$;
  END IF;
END;
$$;

COMMENT ON TABLE public.voya_stay_storefront_config IS
  'Database-admin provisioned singleton. Public VOYA Stay remains disabled and unassigned until explicitly configured.';
COMMENT ON TABLE public.voya_stay_public_listings IS
  'Allowlisted guest-visible property copy, kept separate from private operational property data.';
COMMENT ON TABLE public.voya_stay_public_listing_images IS
  'References approved, re-encoded WebP derivatives in the dedicated public bucket; private source images stay in property-images.';

CREATE OR REPLACE FUNCTION public.publish_voya_stay_public_listing_v1(
  p_organization_id uuid,
  p_property_id uuid,
  p_slug text,
  p_title text,
  p_description text,
  p_area_label text,
  p_bedrooms integer,
  p_max_guests integer,
  p_amenities text[],
  p_images jsonb,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_config public.voya_stay_storefront_config%ROWTYPE;
  v_property public.properties%ROWTYPE;
  v_listing_id uuid;
  v_listing_version integer;
  v_payload jsonb;
  v_existing public.voya_stay_publication_commands%ROWTYPE;
  v_image jsonb;
  v_source_image_id uuid;
  v_storage_path text;
  v_position integer;
  v_image_count integer := 0;
  v_image_key_count integer;
  v_result jsonb;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'public listing publication is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_config FROM public.voya_stay_storefront_config WHERE singleton = true;
  IF NOT FOUND OR NOT v_config.storefront_enabled OR v_config.organization_id IS DISTINCT FROM p_organization_id THEN
    RAISE EXCEPTION 'public storefront is not configured for this organization' USING ERRCODE = '42501';
  END IF;
  SELECT property_record.* INTO v_property
  FROM public.properties AS property_record
  JOIN public.organizations AS organization_record ON organization_record.id = property_record.organization_id
  WHERE property_record.organization_id = p_organization_id
    AND property_record.id = p_property_id
    AND property_record.status = 'active'
    AND organization_record.status = 'active'
  FOR UPDATE OF property_record;
  IF NOT FOUND THEN RAISE EXCEPTION 'active property is required' USING ERRCODE = '22023'; END IF;

  IF p_slug IS NULL OR p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    OR char_length(p_slug) NOT BETWEEN 3 AND 80
    OR p_title IS NULL OR char_length(btrim(p_title)) NOT BETWEEN 1 AND 120
    OR p_description IS NULL OR char_length(btrim(p_description)) NOT BETWEEN 1 AND 2500
    OR p_area_label IS NULL OR char_length(btrim(p_area_label)) NOT BETWEEN 1 AND 100
    OR p_bedrooms IS NULL OR p_bedrooms NOT BETWEEN 0 AND 100
    OR p_max_guests IS NULL OR p_max_guests NOT BETWEEN 1 AND 50
    OR p_amenities IS NULL OR cardinality(p_amenities) > 20
    OR EXISTS (SELECT 1 FROM unnest(p_amenities) AS amenity(value) WHERE char_length(btrim(amenity.value)) NOT BETWEEN 1 AND 50)
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160
    OR jsonb_typeof(p_images) IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_images) NOT BETWEEN 1 AND 12 THEN
    RAISE EXCEPTION 'public listing input is invalid' USING ERRCODE = '22023';
  END IF;

  v_payload := jsonb_build_object(
    'property_id', p_property_id, 'slug', p_slug, 'title', btrim(p_title),
    'description', btrim(p_description), 'area_label', btrim(p_area_label),
    'bedrooms', p_bedrooms, 'max_guests', p_max_guests, 'amenities', p_amenities,
    'images', p_images
  );
  PERFORM pg_advisory_xact_lock(pg_catalog.hashtextextended(p_organization_id::text || ':voya-stay-publish:' || p_idempotency_key, 0));
  SELECT command_record.* INTO v_existing
  FROM public.voya_stay_publication_commands AS command_record
  WHERE command_record.organization_id = p_organization_id
    AND command_record.command = 'publish'
    AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.payload IS DISTINCT FROM v_payload THEN
      RAISE EXCEPTION 'idempotency key belongs to a different publication' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.result;
  END IF;

  FOR v_image IN SELECT image_row.value FROM jsonb_array_elements(p_images) AS image_row(value) LOOP
    SELECT count(*)::integer INTO v_image_key_count FROM jsonb_object_keys(v_image);
    IF jsonb_typeof(v_image) IS DISTINCT FROM 'object'
      OR v_image_key_count <> 3
      OR v_image->>'source_image_id' IS NULL
      OR v_image->>'public_storage_path' IS NULL
      OR v_image->>'position' IS NULL THEN
      RAISE EXCEPTION 'public listing image input is invalid' USING ERRCODE = '22023';
    END IF;
    v_source_image_id := (v_image->>'source_image_id')::uuid;
    v_storage_path := v_image->>'public_storage_path';
    v_position := (v_image->>'position')::integer;
    IF v_storage_path !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]webp$'
      OR v_position NOT BETWEEN 0 AND 11
      OR NOT EXISTS (
        SELECT 1 FROM public.property_images AS source_image
        WHERE source_image.organization_id = p_organization_id
          AND source_image.property_id = p_property_id
          AND source_image.id = v_source_image_id
          AND source_image.status = 'active'
          AND source_image.storage_bucket = 'property-images'
      ) THEN
      RAISE EXCEPTION 'public image source is not active for this property' USING ERRCODE = '22023';
    END IF;
    v_image_count := v_image_count + 1;
  END LOOP;
  IF v_image_count <> jsonb_array_length(p_images) THEN
    RAISE EXCEPTION 'public listing image set is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT listing.id, listing.version INTO v_listing_id, v_listing_version
  FROM public.voya_stay_public_listings AS listing
  WHERE listing.organization_id = p_organization_id AND listing.property_id = p_property_id
  FOR UPDATE;
  IF v_listing_id IS NULL THEN
    INSERT INTO public.voya_stay_public_listings (
      organization_id, property_id, slug, title, description, area_label,
      bedrooms, max_guests, amenities, status, version, published_at,
      created_by_membership_id, updated_by_membership_id
    ) VALUES (
      p_organization_id, p_property_id, p_slug, btrim(p_title), btrim(p_description),
      btrim(p_area_label), p_bedrooms, p_max_guests, p_amenities, 'published', 1,
      timezone('utc', now()), v_actor, v_actor
    ) RETURNING id, version INTO v_listing_id, v_listing_version;
  ELSE
    INSERT INTO public.voya_stay_public_media_cleanup (organization_id, listing_id, storage_path)
    SELECT image.organization_id, image.listing_id, image.storage_path
    FROM public.voya_stay_public_listing_images AS image
    WHERE image.organization_id = p_organization_id AND image.listing_id = v_listing_id
    ON CONFLICT (storage_path) DO NOTHING;
    DELETE FROM public.voya_stay_public_listing_images
    WHERE organization_id = p_organization_id AND listing_id = v_listing_id;
    UPDATE public.voya_stay_public_listings AS listing
    SET slug = p_slug,
        title = btrim(p_title),
        description = btrim(p_description),
        area_label = btrim(p_area_label),
        bedrooms = p_bedrooms,
        max_guests = p_max_guests,
        amenities = p_amenities,
        status = 'published',
        version = listing.version + 1,
        published_at = timezone('utc', now()),
        updated_by_membership_id = v_actor,
        updated_at = timezone('utc', now())
    WHERE listing.organization_id = p_organization_id AND listing.id = v_listing_id
    RETURNING version INTO v_listing_version;
  END IF;

  FOR v_image IN SELECT image_row.value FROM jsonb_array_elements(p_images) AS image_row(value) LOOP
    INSERT INTO public.voya_stay_public_listing_images (
      organization_id, listing_id, property_id, source_image_id, storage_path, position
    ) VALUES (
      p_organization_id, v_listing_id, p_property_id,
      (v_image->>'source_image_id')::uuid,
      v_image->>'public_storage_path',
      (v_image->>'position')::integer
    );
  END LOOP;

  v_result := jsonb_build_object('listing_id', v_listing_id, 'version', v_listing_version);
  INSERT INTO public.voya_stay_publication_commands (
    organization_id, command, idempotency_key, payload, result, listing_id, actor_membership_id
  ) VALUES (
    p_organization_id, 'publish', p_idempotency_key, v_payload, v_result, v_listing_id, v_actor
  );
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'voya_stay.listing.published',
    'voya_stay_public_listing', v_listing_id, 'success', p_request_id,
    jsonb_build_object('property_id', p_property_id, 'slug', p_slug, 'image_count', v_image_count)
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id, 'voya_stay.listing.published', 1,
    'voya-stay-listing-published:' || v_listing_id::text || ':' || v_listing_version::text,
    jsonb_build_object('listing_id', v_listing_id)
  );
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.unpublish_voya_stay_public_listing_v1(
  p_organization_id uuid,
  p_listing_id uuid,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_config public.voya_stay_storefront_config%ROWTYPE;
  v_listing public.voya_stay_public_listings%ROWTYPE;
  v_existing public.voya_stay_publication_commands%ROWTYPE;
  v_payload jsonb;
  v_result jsonb;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'public listing unpublication is not permitted' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_config FROM public.voya_stay_storefront_config WHERE singleton = true;
  IF NOT FOUND OR NOT v_config.storefront_enabled OR v_config.organization_id IS DISTINCT FROM p_organization_id THEN
    RAISE EXCEPTION 'public storefront is not configured for this organization' USING ERRCODE = '42501';
  END IF;
  IF p_listing_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'unpublish input is invalid' USING ERRCODE = '22023';
  END IF;
  v_payload := jsonb_build_object('listing_id', p_listing_id, 'expected_version', p_expected_version);
  PERFORM pg_advisory_xact_lock(pg_catalog.hashtextextended(p_organization_id::text || ':voya-stay-unpublish:' || p_idempotency_key, 0));
  SELECT command_record.* INTO v_existing
  FROM public.voya_stay_publication_commands AS command_record
  WHERE command_record.organization_id = p_organization_id
    AND command_record.command = 'unpublish'
    AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.payload IS DISTINCT FROM v_payload THEN
      RAISE EXCEPTION 'idempotency key belongs to a different unpublication' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.result;
  END IF;
  SELECT listing.* INTO v_listing
  FROM public.voya_stay_public_listings AS listing
  WHERE listing.organization_id = p_organization_id AND listing.id = p_listing_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'public listing was not found' USING ERRCODE = '22023'; END IF;
  IF v_listing.version <> p_expected_version THEN
    RAISE EXCEPTION 'public listing changed; reload and retry' USING ERRCODE = '40001';
  END IF;
  INSERT INTO public.voya_stay_public_media_cleanup (organization_id, listing_id, storage_path)
  SELECT image.organization_id, image.listing_id, image.storage_path
  FROM public.voya_stay_public_listing_images AS image
  WHERE image.organization_id = p_organization_id AND image.listing_id = p_listing_id
  ON CONFLICT (storage_path) DO NOTHING;
  DELETE FROM public.voya_stay_public_listing_images
  WHERE organization_id = p_organization_id AND listing_id = p_listing_id;
  IF v_listing.status = 'published' THEN
    UPDATE public.voya_stay_public_listings AS listing
    SET status = 'unpublished', published_at = NULL,
        version = listing.version + 1,
        updated_by_membership_id = v_actor,
        updated_at = timezone('utc', now())
    WHERE listing.organization_id = p_organization_id AND listing.id = p_listing_id
    RETURNING * INTO v_listing;
  END IF;
  v_result := jsonb_build_object('listing_id', v_listing.id, 'version', v_listing.version);
  INSERT INTO public.voya_stay_publication_commands (
    organization_id, command, idempotency_key, payload, result, listing_id, actor_membership_id
  ) VALUES (
    p_organization_id, 'unpublish', p_idempotency_key, v_payload, v_result, v_listing.id, v_actor
  );
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'voya_stay.listing.unpublished',
    'voya_stay_public_listing', v_listing.id, 'success', p_request_id,
    jsonb_build_object('status', 'published', 'version', p_expected_version),
    jsonb_build_object('status', 'unpublished', 'version', v_listing.version)
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id, 'voya_stay.listing.unpublished', 1,
    'voya-stay-listing-unpublished:' || v_listing.id::text || ':' || v_listing.version::text,
    jsonb_build_object('listing_id', v_listing.id)
  );
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_voya_stay_public_listings_v1(
  p_destination text DEFAULT NULL,
  p_check_in date DEFAULT NULL,
  p_check_out date DEFAULT NULL,
  p_guests integer DEFAULT NULL,
  p_bedrooms integer DEFAULT NULL
)
RETURNS TABLE (
  slug text,
  title text,
  description text,
  area_label text,
  bedrooms integer,
  max_guests integer,
  amenities text[],
  image_paths text[],
  advisory_available boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF (p_check_in IS NULL) <> (p_check_out IS NULL)
    OR (p_check_in IS NOT NULL AND p_check_in >= p_check_out)
    OR (p_check_in IS NOT NULL AND p_check_in < current_date)
    OR (p_guests IS NOT NULL AND p_guests NOT BETWEEN 1 AND 50)
    OR (p_bedrooms IS NOT NULL AND p_bedrooms NOT BETWEEN 0 AND 100)
    OR (p_destination IS NOT NULL AND char_length(btrim(p_destination)) > 100) THEN
    RAISE EXCEPTION 'public search criteria are invalid' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT listing.slug, listing.title, listing.description, listing.area_label,
    listing.bedrooms, listing.max_guests, listing.amenities,
    coalesce(array_agg(image.storage_path ORDER BY image.position)
      FILTER (WHERE image.storage_path IS NOT NULL), ARRAY[]::text[]),
    CASE WHEN p_check_in IS NULL THEN NULL::boolean ELSE NOT EXISTS (
      SELECT 1 FROM public.property_occupancies AS occupancy
      WHERE occupancy.organization_id = listing.organization_id
        AND occupancy.property_id = listing.property_id
        AND daterange(occupancy.start_date, occupancy.end_date, '[)')
          && daterange(p_check_in, p_check_out, '[)')
    ) END
  FROM public.voya_stay_storefront_config AS config
  -- A suspended tenant must fail closed on the public read path exactly as it
  -- already does on publication. An inner join (not a WHERE predicate) keeps
  -- the behavior identical when the configured organization is missing.
  JOIN public.organizations AS organization_record
    ON organization_record.id = config.organization_id
    AND organization_record.status = 'active'
  JOIN public.voya_stay_public_listings AS listing
    ON listing.organization_id = config.organization_id AND listing.status = 'published'
  JOIN public.properties AS property_record
    ON property_record.organization_id = listing.organization_id
    AND property_record.id = listing.property_id
    AND property_record.status = 'active'
  LEFT JOIN public.voya_stay_public_listing_images AS image
    ON image.organization_id = listing.organization_id AND image.listing_id = listing.id
  WHERE config.singleton = true AND config.storefront_enabled = true
    AND config.organization_id IS NOT NULL
    AND (p_destination IS NULL OR listing.area_label ILIKE '%' || btrim(p_destination) || '%')
    AND (p_guests IS NULL OR listing.max_guests >= p_guests)
    AND (p_bedrooms IS NULL OR listing.bedrooms >= p_bedrooms)
  GROUP BY listing.organization_id, listing.id, listing.slug, listing.title,
    listing.description, listing.area_label, listing.bedrooms, listing.max_guests,
    listing.amenities, listing.published_at
  ORDER BY listing.published_at DESC, listing.slug
  LIMIT 100;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_voya_stay_public_listing_v1(
  p_slug text,
  p_check_in date DEFAULT NULL,
  p_check_out date DEFAULT NULL
)
RETURNS TABLE (
  slug text,
  title text,
  description text,
  area_label text,
  bedrooms integer,
  max_guests integer,
  amenities text[],
  image_paths text[],
  advisory_available boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_slug IS NULL OR char_length(p_slug) > 80 THEN
    RAISE EXCEPTION 'public listing slug is invalid' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT listing.slug, listing.title, listing.description, listing.area_label,
    listing.bedrooms, listing.max_guests, listing.amenities, listing.image_paths,
    listing.advisory_available
  FROM public.list_voya_stay_public_listings_v1(NULL, p_check_in, p_check_out, NULL, NULL) AS listing
  WHERE listing.slug = p_slug
  LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.capture_voya_stay_lead_v1(
  p_slug text,
  p_guest_name text,
  p_phone text,
  p_email text,
  p_check_in date,
  p_check_out date,
  p_guests integer,
  p_message text,
  p_consent_version text,
  p_contact_consent boolean,
  p_contact_fingerprint text,
  p_payload_fingerprint text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_config public.voya_stay_storefront_config%ROWTYPE;
  v_listing public.voya_stay_public_listings%ROWTYPE;
  v_existing public.voya_stay_guest_request_idempotency%ROWTYPE;
  v_phone text := public.crm_normalize_phone(p_phone);
  v_email text := public.crm_normalize_email(p_email);
  v_lead_id uuid;
  v_attempts integer;
  v_bucket_start timestamptz := date_trunc('hour', now());
  v_idempotency_key text;
BEGIN
  SELECT * INTO v_config FROM public.voya_stay_storefront_config WHERE singleton = true;
  IF NOT FOUND OR NOT v_config.storefront_enabled OR NOT v_config.requests_enabled
    OR v_config.organization_id IS NULL OR v_config.privacy_notice_version IS NULL THEN
    RAISE EXCEPTION 'guest requests are not enabled' USING ERRCODE = '55000';
  END IF;
  -- A suspended tenant must stop collecting guest PII. Reuse the disabled
  -- storefront error so the response reveals nothing about organization state,
  -- and fail closed when the configured organization row is missing.
  IF NOT EXISTS (
    SELECT 1 FROM public.organizations AS organization_record
    WHERE organization_record.id = v_config.organization_id
      AND organization_record.status = 'active'
  ) THEN
    RAISE EXCEPTION 'guest requests are not enabled' USING ERRCODE = '55000';
  END IF;
  IF p_idempotency_key IS NULL OR p_idempotency_key !~ '^[0-9a-f-]{36}$'
    OR p_payload_fingerprint IS NULL OR p_payload_fingerprint !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'guest request identity is invalid' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(pg_catalog.hashtextextended(v_config.organization_id::text || ':voya-stay-request:' || p_idempotency_key, 0));
  SELECT request_record.* INTO v_existing
  FROM public.voya_stay_guest_request_idempotency AS request_record
  WHERE request_record.organization_id = v_config.organization_id
    AND request_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.payload_fingerprint IS DISTINCT FROM p_payload_fingerprint THEN
      RAISE EXCEPTION 'idempotency key belongs to a different request' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.lead_id;
  END IF;

  IF p_slug IS NULL OR p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    OR p_guest_name IS NULL OR char_length(btrim(p_guest_name)) NOT BETWEEN 1 AND 160
    OR (v_phone IS NULL AND v_email IS NULL)
    OR (p_check_in IS NULL) OR (p_check_out IS NULL) OR p_check_in < current_date OR p_check_in >= p_check_out
    OR p_guests IS NULL OR p_guests NOT BETWEEN 1 AND 50
    OR (p_message IS NOT NULL AND char_length(btrim(p_message)) > 1000)
    OR p_contact_consent IS DISTINCT FROM true
    OR p_consent_version IS DISTINCT FROM v_config.privacy_notice_version
    OR p_contact_fingerprint IS NULL OR p_contact_fingerprint !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'guest request input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT listing.* INTO v_listing
  FROM public.voya_stay_public_listings AS listing
  JOIN public.properties AS property_record
    ON property_record.organization_id = listing.organization_id
    AND property_record.id = listing.property_id AND property_record.status = 'active'
  WHERE listing.organization_id = v_config.organization_id
    AND listing.slug = p_slug AND listing.status = 'published';
  IF NOT FOUND OR p_guests > v_listing.max_guests THEN
    RAISE EXCEPTION 'requested public listing was not found' USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.voya_stay_request_rate_limits
  WHERE organization_id = v_config.organization_id
    AND bucket_start < now() - interval '48 hours';
  INSERT INTO public.voya_stay_request_rate_limits (
    organization_id, fingerprint, bucket_start, attempts
  ) VALUES (
    v_config.organization_id, p_contact_fingerprint, v_bucket_start, 1
  )
  ON CONFLICT (organization_id, fingerprint, bucket_start) DO UPDATE
    SET attempts = public.voya_stay_request_rate_limits.attempts + 1,
        updated_at = timezone('utc', now())
    WHERE public.voya_stay_request_rate_limits.attempts < 5
  RETURNING attempts INTO v_attempts;
  IF v_attempts IS NULL THEN
    RAISE EXCEPTION 'guest request rate limit reached' USING ERRCODE = 'P0002';
  END IF;

  v_idempotency_key := 'voya-stay:' || p_idempotency_key;
  INSERT INTO public.leads (
    organization_id, title, name, phone, email, normalized_phone, normalized_email,
    source, status, requested_area, requested_check_in, requested_check_out,
    guests, notes, idempotency_key, requested_property_id, requested_property_title,
    contact_consent_version, contact_consented_at
  ) VALUES (
    v_config.organization_id, left('طلب إقامة - ' || v_listing.title, 160), btrim(p_guest_name),
    NULLIF(btrim(p_phone), ''), NULLIF(lower(btrim(p_email)), ''), v_phone, v_email,
    'voya_stay', 'new', v_listing.area_label, p_check_in, p_check_out,
    p_guests, NULLIF(btrim(p_message), ''), v_idempotency_key,
    v_listing.property_id, v_listing.title, v_config.privacy_notice_version,
    timezone('utc', now())
  ) RETURNING id INTO v_lead_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    v_config.organization_id, 'system', NULL, 'lead.created', 'lead', v_lead_id,
    'success', p_request_id, jsonb_build_object(
      'source', 'voya_stay', 'property_id', v_listing.property_id,
      'check_in', p_check_in, 'check_out', p_check_out, 'guests', p_guests,
      'contact_consent_version', v_config.privacy_notice_version
    )
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    v_config.organization_id, 'lead.created', 1,
    'lead-v1:' || v_lead_id::text, jsonb_build_object('lead_id', v_lead_id)
  );
  INSERT INTO public.voya_stay_guest_request_idempotency (
    organization_id, idempotency_key, payload_fingerprint, lead_id
  ) VALUES (
    v_config.organization_id, p_idempotency_key, p_payload_fingerprint, v_lead_id
  );
  RETURN v_lead_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_voya_stay_lead_property_titles_v1(p_organization_id uuid)
RETURNS TABLE (
  lead_id uuid,
  property_title text,
  contact_consent_version text,
  contact_consented_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_role text;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.role INTO v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'viewer') THEN
    RAISE EXCEPTION 'CRM request listing read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT lead_record.id, lead_record.requested_property_title,
    lead_record.contact_consent_version, lead_record.contact_consented_at
  FROM public.leads AS lead_record
  WHERE lead_record.organization_id = p_organization_id
    AND lead_record.source = 'voya_stay'
    AND lead_record.requested_property_id IS NOT NULL
  ORDER BY lead_record.created_at DESC, lead_record.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_voya_stay_publication_states_v1(p_organization_id uuid)
RETURNS TABLE (
  property_id uuid, listing_id uuid, slug text, public_title text,
  status text, version integer, public_description text, area_label text,
  bedrooms integer, max_guests integer, amenities text[], pending_media_cleanup boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'public listing publication state is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT listing.property_id, listing.id, listing.slug, listing.title, listing.status,
    listing.version, listing.description, listing.area_label, listing.bedrooms,
    listing.max_guests, listing.amenities,
    EXISTS (
      SELECT 1 FROM public.voya_stay_public_media_cleanup AS cleanup
      WHERE cleanup.organization_id = listing.organization_id AND cleanup.listing_id = listing.id
    )
  FROM public.voya_stay_public_listings AS listing
  WHERE listing.organization_id = p_organization_id
  ORDER BY listing.created_at, listing.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_voya_stay_public_request_config_v1()
RETURNS TABLE (requests_enabled boolean, privacy_notice_url text, privacy_notice_version text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  RETURN QUERY
  SELECT config.storefront_enabled AND config.requests_enabled,
    config.privacy_notice_url, config.privacy_notice_version
  FROM public.voya_stay_storefront_config AS config
  WHERE config.singleton = true;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_voya_stay_media_cleanup_v1(p_organization_id uuid, p_listing_id uuid)
RETURNS TABLE (cleanup_id uuid, storage_path text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  RETURN QUERY
  SELECT cleanup.id, cleanup.storage_path
  FROM public.voya_stay_public_media_cleanup AS cleanup
  JOIN public.voya_stay_public_listings AS listing
    ON listing.organization_id = cleanup.organization_id AND listing.id = cleanup.listing_id
  WHERE cleanup.organization_id = p_organization_id
    AND cleanup.listing_id = p_listing_id
  ORDER BY cleanup.created_at, cleanup.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_voya_stay_media_cleanup_v1(p_organization_id uuid, p_cleanup_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  DELETE FROM public.voya_stay_public_media_cleanup
  WHERE id = p_cleanup_id AND organization_id = p_organization_id;
  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.publish_voya_stay_public_listing_v1(uuid,uuid,text,text,text,text,integer,integer,text[],jsonb,text,uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.unpublish_voya_stay_public_listing_v1(uuid,uuid,integer,text,uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_voya_stay_public_listings_v1(text,date,date,integer,integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_voya_stay_public_listing_v1(text,date,date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.capture_voya_stay_lead_v1(text,text,text,text,date,date,integer,text,text,boolean,text,text,text,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_voya_stay_lead_property_titles_v1(uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_voya_stay_publication_states_v1(uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.get_voya_stay_public_request_config_v1() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_voya_stay_media_cleanup_v1(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_voya_stay_media_cleanup_v1(uuid, uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.publish_voya_stay_public_listing_v1(uuid,uuid,text,text,text,text,integer,integer,text[],jsonb,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unpublish_voya_stay_public_listing_v1(uuid,uuid,integer,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_voya_stay_public_listings_v1(text,date,date,integer,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_voya_stay_public_listing_v1(text,date,date) TO service_role;
GRANT EXECUTE ON FUNCTION public.capture_voya_stay_lead_v1(text,text,text,text,date,date,integer,text,text,boolean,text,text,text,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.list_voya_stay_lead_property_titles_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_voya_stay_publication_states_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_voya_stay_public_request_config_v1() TO service_role;
GRANT EXECUTE ON FUNCTION public.list_voya_stay_media_cleanup_v1(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_voya_stay_media_cleanup_v1(uuid, uuid) TO service_role;

GRANT USAGE ON SCHEMA public TO service_role;
