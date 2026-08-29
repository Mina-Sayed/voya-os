-- Terminal privacy invariant: whenever a data-entry draft becomes expired or
-- rejected, no active intake metadata may remain reachable. Storage object
-- deletion is still performed by the trusted application/worker cleanup path;
-- this trigger makes the metadata lifecycle atomic with the terminal state.

CREATE OR REPLACE FUNCTION public.archive_ai_data_entry_inputs_on_terminal_status()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.status IN ('expired', 'rejected')
    AND OLD.status IS DISTINCT FROM NEW.status THEN
    UPDATE public.ai_data_entry_inputs AS input
    SET status = 'archived'
    WHERE input.organization_id = NEW.organization_id
      AND input.draft_id = NEW.id
      AND input.status = 'active';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ai_data_entry_terminal_input_archival ON public.ai_data_entry_drafts;
CREATE TRIGGER trg_ai_data_entry_terminal_input_archival
AFTER UPDATE OF status ON public.ai_data_entry_drafts
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status AND NEW.status IN ('expired', 'rejected'))
EXECUTE FUNCTION public.archive_ai_data_entry_inputs_on_terminal_status();

REVOKE ALL ON FUNCTION public.archive_ai_data_entry_inputs_on_terminal_status() FROM PUBLIC, anon, authenticated;

-- Workspace policy requires MFA AAL2 before tenant data is exposed or mutated.
-- Server Actions already enforce this, but authenticated Supabase RPCs are a
-- separate remotely callable boundary. Keep the proven business/concurrency
-- implementations intact under non-public names and expose only AAL2 wrappers.
CREATE OR REPLACE FUNCTION public.require_ai_data_entry_aal2_v1()
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog
AS $$
BEGIN
  IF coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' THEN
    RAISE EXCEPTION 'MFA AAL2 is required for AI data entry' USING ERRCODE = '42501';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.require_ai_data_entry_aal2_v1() FROM PUBLIC, anon, authenticated, service_role;

ALTER FUNCTION public.create_ai_data_entry_draft_v1(uuid,text,text,uuid)
  RENAME TO create_ai_data_entry_draft_without_aal2_v1;
ALTER FUNCTION public.register_ai_data_entry_input_v1(uuid,uuid,text,text,bigint,text,text,uuid)
  RENAME TO register_ai_data_entry_input_without_aal2_v1;
ALTER FUNCTION public.submit_ai_data_entry_draft_v1(uuid,uuid,text,uuid)
  RENAME TO submit_ai_data_entry_draft_without_aal2_v1;
ALTER FUNCTION public.list_ai_data_entry_drafts_v1(uuid,integer)
  RENAME TO list_ai_data_entry_drafts_without_aal2_v1;
ALTER FUNCTION public.get_ai_data_entry_draft_v1(uuid,uuid)
  RENAME TO get_ai_data_entry_draft_without_aal2_v1;
ALTER FUNCTION public.list_ai_data_entry_inputs_v1(uuid,uuid)
  RENAME TO list_ai_data_entry_inputs_without_aal2_v1;
ALTER FUNCTION public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid)
  RENAME TO claim_ai_data_entry_confirmation_without_aal2_v3;
ALTER FUNCTION public.reject_ai_data_entry_draft_v1(uuid,uuid,integer,text,uuid)
  RENAME TO reject_ai_data_entry_draft_without_aal2_v1;

REVOKE ALL ON FUNCTION public.create_ai_data_entry_draft_without_aal2_v1(uuid,text,text,uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.register_ai_data_entry_input_without_aal2_v1(uuid,uuid,text,text,bigint,text,text,uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.submit_ai_data_entry_draft_without_aal2_v1(uuid,uuid,text,uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_ai_data_entry_drafts_without_aal2_v1(uuid,integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_ai_data_entry_draft_without_aal2_v1(uuid,uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_ai_data_entry_inputs_without_aal2_v1(uuid,uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.claim_ai_data_entry_confirmation_without_aal2_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.reject_ai_data_entry_draft_without_aal2_v1(uuid,uuid,integer,text,uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_source_text text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_ai_data_entry_aal2_v1();
  RETURN public.create_ai_data_entry_draft_without_aal2_v1(
    p_organization_id, p_source_text, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.register_ai_data_entry_input_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_checksum_sha256 text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_ai_data_entry_aal2_v1();
  RETURN public.register_ai_data_entry_input_without_aal2_v1(
    p_organization_id, p_draft_id, p_storage_path, p_mime_type, p_byte_size,
    p_checksum_sha256, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_ai_data_entry_aal2_v1();
  RETURN public.submit_ai_data_entry_draft_without_aal2_v1(
    p_organization_id, p_draft_id, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_ai_data_entry_drafts_v1(
  p_organization_id uuid,
  p_limit integer DEFAULT 30
)
RETURNS TABLE (
  id uuid, ai_run_id uuid, status text, source_kind text, version integer,
  error_code text, expires_at timestamptz, created_at timestamptz, updated_at timestamptz,
  created_by_membership_id uuid, input_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_ai_data_entry_aal2_v1();
  RETURN QUERY
  SELECT * FROM public.list_ai_data_entry_drafts_without_aal2_v1(p_organization_id, p_limit);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_draft_id uuid
)
RETURNS TABLE (
  id uuid, ai_run_id uuid, status text, source_text text, source_kind text,
  extraction_payload jsonb, confirmation_payload jsonb, application_result jsonb,
  error_code text, version integer, expires_at timestamptz,
  created_at timestamptz, updated_at timestamptz, created_by_membership_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_ai_data_entry_aal2_v1();
  RETURN QUERY
  SELECT * FROM public.get_ai_data_entry_draft_without_aal2_v1(p_organization_id, p_draft_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.list_ai_data_entry_inputs_v1(
  p_organization_id uuid,
  p_draft_id uuid
)
RETURNS TABLE (
  id uuid, storage_bucket text, storage_path text, mime_type text, byte_size bigint,
  checksum_sha256 text, status text, mapped_property_id uuid, mapped_at timestamptz, created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_ai_data_entry_aal2_v1();
  RETURN QUERY
  SELECT * FROM public.list_ai_data_entry_inputs_without_aal2_v1(p_organization_id, p_draft_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_ai_data_entry_confirmation_v3(
  p_organization_id uuid,
  p_draft_id uuid,
  p_confirmation_payload jsonb,
  p_excluded_client_indexes integer[],
  p_excluded_property_indexes integer[],
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS TABLE (outcome text, execution_token uuid, draft_version integer, application_result jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_ai_data_entry_aal2_v1();
  RETURN QUERY
  SELECT *
  FROM public.claim_ai_data_entry_confirmation_without_aal2_v3(
    p_organization_id,
    p_draft_id,
    p_confirmation_payload,
    p_excluded_client_indexes,
    p_excluded_property_indexes,
    p_expected_version,
    p_idempotency_key,
    p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_ai_data_entry_aal2_v1();
  RETURN public.reject_ai_data_entry_draft_without_aal2_v1(
    p_organization_id, p_draft_id, p_expected_version, p_idempotency_key, p_request_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_ai_data_entry_draft_v1(uuid,text,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.register_ai_data_entry_input_v1(uuid,uuid,text,text,bigint,text,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.submit_ai_data_entry_draft_v1(uuid,uuid,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_ai_data_entry_drafts_v1(uuid,integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_ai_data_entry_draft_v1(uuid,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_ai_data_entry_inputs_v1(uuid,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reject_ai_data_entry_draft_v1(uuid,uuid,integer,text,uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
  public.create_ai_data_entry_draft_v1(uuid,text,text,uuid),
  public.register_ai_data_entry_input_v1(uuid,uuid,text,text,bigint,text,text,uuid),
  public.submit_ai_data_entry_draft_v1(uuid,uuid,text,uuid),
  public.list_ai_data_entry_drafts_v1(uuid,integer),
  public.get_ai_data_entry_draft_v1(uuid,uuid),
  public.list_ai_data_entry_inputs_v1(uuid,uuid),
  public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid),
  public.reject_ai_data_entry_draft_v1(uuid,uuid,integer,text,uuid)
TO authenticated;

-- AI-confirmed property-image registration must not become source-of-record
-- before its intake input is mapped. Keep the proven generic registration
-- implementation intact for manual workflows, but make the AI idempotency-key
-- path register the property image and mark the intake input in this same
-- PostgreSQL transaction. Any raised error therefore rolls both writes back;
-- a lost response after commit leaves both writes committed and retryable.
ALTER FUNCTION public.register_property_image_v1(uuid,uuid,text,text,bigint,integer,integer,text,uuid)
  RENAME TO register_property_image_without_ai_mapping_v1;

REVOKE ALL ON FUNCTION public.register_property_image_without_ai_mapping_v1(uuid,uuid,text,text,bigint,integer,integer,text,uuid)
FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.register_property_image_v1(
  p_organization_id uuid,
  p_property_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_width_px integer,
  p_height_px integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_ai_key_parts text[];
  v_actor uuid;
  v_draft public.ai_data_entry_drafts%ROWTYPE;
  v_draft_id uuid;
  v_input public.ai_data_entry_inputs%ROWTYPE;
  v_input_id uuid;
  v_property_index integer;
  v_property_payload jsonb;
  v_image_id uuid;
BEGIN
  IF p_idempotency_key IS NULL OR p_idempotency_key NOT LIKE 'ai-data-entry:%' THEN
    RETURN public.register_property_image_without_ai_mapping_v1(
      p_organization_id, p_property_id, p_storage_path, p_mime_type, p_byte_size,
      p_width_px, p_height_px, p_idempotency_key, p_request_id
    );
  END IF;

  PERFORM public.require_ai_data_entry_aal2_v1();

  v_ai_key_parts := regexp_match(
    p_idempotency_key,
    '^ai-data-entry:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):property:([0-9]+):image:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
  );
  IF v_ai_key_parts IS NULL THEN
    RAISE EXCEPTION 'AI property image idempotency key is invalid' USING ERRCODE = '22023';
  END IF;

  v_draft_id := v_ai_key_parts[1]::uuid;
  v_property_index := v_ai_key_parts[2]::integer;
  v_input_id := v_ai_key_parts[3]::uuid;

  IF split_part(split_part(p_storage_path, '/', 3), '.', 1) <> v_input_id::text THEN
    RAISE EXCEPTION 'AI property image path does not match its intake input' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'AI property image registration is not permitted' USING ERRCODE = '42501';
  END IF;

  -- Preserve the established confirmation lock order: draft, then input, then
  -- the generic property registration's per-property lock.
  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.id = v_draft_id
    AND draft.status = 'confirmed'
    AND draft.confirmed_by_membership_id = v_actor
    AND draft.confirmation_execution_token IS NOT NULL
    AND coalesce(draft.confirmation_execution_heartbeat_at, draft.confirmation_execution_claimed_at)
      > timezone('utc', now()) - interval '10 minutes'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI property image confirmation claim is stale' USING ERRCODE = '40001';
  END IF;

  SELECT input.* INTO v_input
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = v_draft_id
    AND input.id = v_input_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI property image intake input is unavailable' USING ERRCODE = '40001';
  END IF;

  IF v_input.status = 'mapped' AND v_input.mapped_property_id IS DISTINCT FROM p_property_id THEN
    RAISE EXCEPTION 'AI property image intake input is already mapped' USING ERRCODE = '40001';
  ELSIF v_input.status NOT IN ('active', 'mapped') THEN
    RAISE EXCEPTION 'AI property image intake input is unavailable' USING ERRCODE = '40001';
  END IF;

  IF jsonb_typeof(v_draft.confirmation_payload -> 'properties') <> 'array'
    OR v_property_index < 0
    OR v_property_index >= jsonb_array_length(v_draft.confirmation_payload -> 'properties') THEN
    RAISE EXCEPTION 'AI property image property selection is stale' USING ERRCODE = '40001';
  END IF;

  v_property_payload := v_draft.confirmation_payload -> 'properties' -> v_property_index;
  IF jsonb_typeof(v_property_payload -> 'imageInputIds') <> 'array'
    OR NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(v_property_payload -> 'imageInputIds') AS image_id(value)
      WHERE image_id.value = v_input_id::text
    ) THEN
    RAISE EXCEPTION 'AI property image was not confirmed for this property' USING ERRCODE = '40001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(v_draft.application_result -> 'properties') = 'array'
          THEN v_draft.application_result -> 'properties'
        ELSE '[]'::jsonb
      END
    ) AS result(item)
    WHERE result.item ->> 'index' = v_property_index::text
      AND result.item ->> 'recordId' = p_property_id::text
  ) THEN
    RAISE EXCEPTION 'AI property image property record is not durable yet' USING ERRCODE = '40001';
  END IF;

  v_image_id := public.register_property_image_without_ai_mapping_v1(
    p_organization_id, p_property_id, p_storage_path, p_mime_type, p_byte_size,
    p_width_px, p_height_px, p_idempotency_key, p_request_id
  );

  -- A replay after a committed-but-lost response reuses the same image row and
  -- returns it without creating duplicate mapping evidence.
  IF v_input.status = 'mapped' THEN
    RETURN v_image_id;
  END IF;

  UPDATE public.ai_data_entry_inputs
  SET status = 'mapped', mapped_property_id = p_property_id, mapped_at = timezone('utc', now())
  WHERE organization_id = p_organization_id
    AND draft_id = v_draft_id
    AND id = v_input_id
    AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI property image intake mapping changed concurrently' USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.input.mapped',
    'ai_data_entry_input', v_input_id, 'success', p_request_id,
    jsonb_build_object('property_id', p_property_id, 'property_image_id', v_image_id)
  );

  RETURN v_image_id;
END;
$$;

REVOKE ALL ON FUNCTION public.register_property_image_v1(uuid,uuid,text,text,bigint,integer,integer,text,uuid)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_property_image_v1(uuid,uuid,text,text,bigint,integer,integer,text,uuid)
TO authenticated;
