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
