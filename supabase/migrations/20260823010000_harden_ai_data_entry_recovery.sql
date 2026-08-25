-- Harden AI data-entry recovery after the final PR review.
--
-- The operator's exclusions become part of the durable claim, active
-- confirmation executions publish a trusted heartbeat, extraction start is
-- idempotent across provider retries, AI provider calls revalidate their
-- outbox lease, and terminal worker failure moves the run and draft together
-- before private-input cleanup is allowed.

ALTER TABLE public.ai_data_entry_drafts
  ADD COLUMN IF NOT EXISTS confirmation_execution_heartbeat_at timestamptz;

UPDATE public.ai_data_entry_drafts
SET confirmation_execution_heartbeat_at = confirmation_execution_claimed_at
WHERE confirmation_execution_token IS NOT NULL
  AND confirmation_execution_heartbeat_at IS NULL;

ALTER TABLE public.ai_data_entry_drafts
  DROP CONSTRAINT IF EXISTS ai_data_entry_draft_execution_heartbeat_consistency;
ALTER TABLE public.ai_data_entry_drafts
  ADD CONSTRAINT ai_data_entry_draft_execution_heartbeat_consistency
  CHECK ((confirmation_execution_token IS NULL) = (confirmation_execution_heartbeat_at IS NULL));

CREATE OR REPLACE FUNCTION public.ai_data_entry_application_seed_v1(
  p_existing jsonb,
  p_excluded_client_indexes integer[],
  p_excluded_property_indexes integer[]
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog
AS $$
DECLARE
  v_result jsonb := jsonb_build_object('clients', '[]'::jsonb, 'properties', '[]'::jsonb, 'images', '[]'::jsonb);
  v_item jsonb;
  v_index integer;
BEGIN
  -- Only durable successful writes survive into a fresh execution claim.
  FOR v_item IN
    SELECT value
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(coalesce(p_existing -> 'clients', '[]'::jsonb)) = 'array'
          THEN coalesce(p_existing -> 'clients', '[]'::jsonb)
        ELSE '[]'::jsonb
      END
    )
  LOOP
    IF jsonb_typeof(v_item) = 'object'
      AND coalesce(v_item ->> 'index', '') ~ '^[0-9]+$'
      AND jsonb_typeof(v_item -> 'recordId') = 'string'
      AND char_length(v_item ->> 'recordId') BETWEEN 1 AND 160 THEN
      v_result := jsonb_set(
        v_result,
        '{clients}',
        (v_result -> 'clients') || jsonb_build_array(jsonb_build_object(
          'index', (v_item ->> 'index')::integer,
          'recordId', v_item ->> 'recordId'
        ))
      );
    END IF;
  END LOOP;

  FOREACH v_index IN ARRAY coalesce(p_excluded_client_indexes, ARRAY[]::integer[])
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_result -> 'clients') AS item
      WHERE (item ->> 'index')::integer = v_index
    ) THEN
      v_result := jsonb_set(
        v_result,
        '{clients}',
        (v_result -> 'clients') || jsonb_build_array(jsonb_build_object(
          'index', v_index,
          'errorCode', 'excluded_by_operator'
        ))
      );
    END IF;
  END LOOP;

  FOR v_item IN
    SELECT value
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(coalesce(p_existing -> 'properties', '[]'::jsonb)) = 'array'
          THEN coalesce(p_existing -> 'properties', '[]'::jsonb)
        ELSE '[]'::jsonb
      END
    )
  LOOP
    IF jsonb_typeof(v_item) = 'object'
      AND coalesce(v_item ->> 'index', '') ~ '^[0-9]+$'
      AND jsonb_typeof(v_item -> 'recordId') = 'string'
      AND char_length(v_item ->> 'recordId') BETWEEN 1 AND 160 THEN
      v_result := jsonb_set(
        v_result,
        '{properties}',
        (v_result -> 'properties') || jsonb_build_array(jsonb_build_object(
          'index', (v_item ->> 'index')::integer,
          'recordId', v_item ->> 'recordId'
        ))
      );
    END IF;
  END LOOP;

  FOREACH v_index IN ARRAY coalesce(p_excluded_property_indexes, ARRAY[]::integer[])
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_result -> 'properties') AS item
      WHERE (item ->> 'index')::integer = v_index
    ) THEN
      v_result := jsonb_set(
        v_result,
        '{properties}',
        (v_result -> 'properties') || jsonb_build_array(jsonb_build_object(
          'index', v_index,
          'errorCode', 'excluded_by_operator'
        ))
      );
    END IF;
  END LOOP;

  FOR v_item IN
    SELECT value
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(coalesce(p_existing -> 'images', '[]'::jsonb)) = 'array'
          THEN coalesce(p_existing -> 'images', '[]'::jsonb)
        ELSE '[]'::jsonb
      END
    )
  LOOP
    IF jsonb_typeof(v_item) = 'object'
      AND coalesce(v_item ->> 'propertyIndex', '') ~ '^[0-9]+$'
      AND jsonb_typeof(v_item -> 'inputId') = 'string'
      AND char_length(v_item ->> 'inputId') BETWEEN 1 AND 160
      AND jsonb_typeof(v_item -> 'recordId') = 'string'
      AND char_length(v_item ->> 'recordId') BETWEEN 1 AND 160 THEN
      v_result := jsonb_set(
        v_result,
        '{images}',
        (v_result -> 'images') || jsonb_build_array(jsonb_build_object(
          'propertyIndex', (v_item ->> 'propertyIndex')::integer,
          'inputId', v_item ->> 'inputId',
          'recordId', v_item ->> 'recordId'
        ))
      );
    END IF;
  END LOOP;

  RETURN v_result;
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
DECLARE
  v_actor uuid;
  v_role text;
  v_draft public.ai_data_entry_drafts%ROWTYPE;
  v_token uuid;
  v_seed jsonb;
  v_client_count integer;
  v_property_count integer;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_confirmation_payload IS NULL
    OR jsonb_typeof(p_confirmation_payload) <> 'object'
    OR jsonb_typeof(p_confirmation_payload -> 'clients') <> 'array'
    OR jsonb_typeof(p_confirmation_payload -> 'properties') <> 'array'
    OR char_length(p_confirmation_payload::text) > 20000
    OR p_excluded_client_indexes IS NULL OR p_excluded_property_indexes IS NULL
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI data-entry confirmation input is invalid' USING ERRCODE = '22023';
  END IF;

  v_client_count := jsonb_array_length(p_confirmation_payload -> 'clients');
  v_property_count := jsonb_array_length(p_confirmation_payload -> 'properties');

  IF EXISTS (
      SELECT 1 FROM unnest(p_excluded_client_indexes) AS excluded(index_value)
      WHERE index_value < 0 OR index_value >= v_client_count
    )
    OR EXISTS (
      SELECT 1 FROM unnest(p_excluded_property_indexes) AS excluded(index_value)
      WHERE index_value < 0 OR index_value >= v_property_count
    )
    OR cardinality(p_excluded_client_indexes) <> (
      SELECT count(DISTINCT index_value)::integer FROM unnest(p_excluded_client_indexes) AS excluded(index_value)
    )
    OR cardinality(p_excluded_property_indexes) <> (
      SELECT count(DISTINCT index_value)::integer FROM unnest(p_excluded_property_indexes) AS excluded(index_value)
    ) THEN
    RAISE EXCEPTION 'AI data-entry exclusion indexes are invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'AI data-entry confirmation is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.id = p_draft_id
    AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI data-entry draft is not permitted' USING ERRCODE = '42501';
  END IF;

  IF v_draft.status = 'applied' AND v_draft.confirmation_idempotency_key = btrim(p_idempotency_key) THEN
    RETURN QUERY SELECT 'applied'::text, NULL::uuid, v_draft.version, v_draft.application_result;
    RETURN;
  END IF;
  IF v_draft.status = 'expired' THEN
    RETURN QUERY SELECT 'expired'::text, NULL::uuid, v_draft.version, v_draft.application_result;
    RETURN;
  END IF;
  IF v_draft.status = 'confirmed'
    AND v_draft.confirmation_execution_token IS NOT NULL
    AND coalesce(v_draft.confirmation_execution_heartbeat_at, v_draft.confirmation_execution_claimed_at)
      > timezone('utc', now()) - interval '10 minutes' THEN
    RETURN QUERY SELECT 'in_progress'::text, NULL::uuid, v_draft.version, v_draft.application_result;
    RETURN;
  END IF;
  IF v_draft.status NOT IN ('ready_for_review', 'partially_applied', 'confirmed') THEN
    RAISE EXCEPTION 'AI data-entry draft is not confirmable' USING ERRCODE = '40001';
  END IF;
  IF v_draft.version <> p_expected_version THEN
    RAISE EXCEPTION 'AI data-entry draft version is stale' USING ERRCODE = '40001';
  END IF;

  IF v_draft.expires_at <= timezone('utc', now()) THEN
    UPDATE public.ai_data_entry_drafts
    SET status = 'expired',
        version = version + 1,
        confirmation_execution_token = NULL,
        confirmation_execution_claimed_at = NULL,
        confirmation_execution_heartbeat_at = NULL
    WHERE organization_id = p_organization_id AND id = p_draft_id;
    SELECT draft.* INTO v_draft
    FROM public.ai_data_entry_drafts AS draft
    WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id;
    RETURN QUERY SELECT 'expired'::text, NULL::uuid, v_draft.version, v_draft.application_result;
    RETURN;
  END IF;

  v_seed := public.ai_data_entry_application_seed_v1(
    v_draft.application_result,
    p_excluded_client_indexes,
    p_excluded_property_indexes
  );
  v_token := gen_random_uuid();

  UPDATE public.ai_data_entry_drafts AS draft
  SET status = 'confirmed',
      confirmation_payload = p_confirmation_payload,
      application_result = v_seed,
      confirmation_idempotency_key = btrim(p_idempotency_key),
      confirmed_by_membership_id = v_actor,
      confirmed_at = coalesce(draft.confirmed_at, timezone('utc', now())),
      confirmation_execution_token = v_token,
      confirmation_execution_claimed_at = timezone('utc', now()),
      confirmation_execution_heartbeat_at = timezone('utc', now()),
      version = draft.version + 1,
      error_code = NULL
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
  RETURNING draft.version, draft.application_result
  INTO v_draft.version, v_draft.application_result;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.confirmation_claimed',
    'ai_data_entry_draft', p_draft_id, 'success', p_request_id,
    jsonb_build_object(
      'confirmation_key', btrim(p_idempotency_key),
      'excluded_clients', cardinality(p_excluded_client_indexes),
      'excluded_properties', cardinality(p_excluded_property_indexes)
    )
  );

  RETURN QUERY SELECT 'claimed'::text, v_token, v_draft.version, v_draft.application_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.heartbeat_ai_data_entry_confirmation_v3(
  p_organization_id uuid,
  p_draft_id uuid,
  p_execution_token uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_count integer;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_execution_token IS NULL THEN
    RAISE EXCEPTION 'AI data-entry heartbeat input is invalid' USING ERRCODE = '22023';
  END IF;

  UPDATE public.ai_data_entry_drafts AS draft
  SET confirmation_execution_heartbeat_at = timezone('utc', now())
  WHERE draft.organization_id = p_organization_id
    AND draft.id = p_draft_id
    AND draft.status = 'confirmed'
    AND draft.confirmation_execution_token = p_execution_token
    AND draft.expires_at > timezone('utc', now());
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_ai_data_entry_confirmation_v2(
  p_organization_id uuid,
  p_draft_id uuid,
  p_execution_token uuid,
  p_status text,
  p_application_result jsonb,
  p_expected_version integer,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_draft public.ai_data_entry_drafts%ROWTYPE;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_execution_token IS NULL
    OR p_status NOT IN ('partially_applied', 'applied')
    OR p_application_result IS NULL OR jsonb_typeof(p_application_result) <> 'object'
    OR char_length(p_application_result::text) > 20000
    OR p_expected_version IS NULL OR p_expected_version < 1 THEN
    RAISE EXCEPTION 'AI data-entry trusted progress input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
  FOR UPDATE;
  IF NOT FOUND OR v_draft.status <> 'confirmed'
    OR v_draft.confirmation_execution_token IS DISTINCT FROM p_execution_token
    OR v_draft.version <> p_expected_version THEN
    RAISE EXCEPTION 'AI data-entry trusted progress claim is stale' USING ERRCODE = '40001';
  END IF;

  UPDATE public.ai_data_entry_drafts
  SET status = p_status,
      application_result = p_application_result,
      progress_idempotency_key = 'trusted:' || p_execution_token::text,
      confirmation_execution_token = NULL,
      confirmation_execution_claimed_at = NULL,
      confirmation_execution_heartbeat_at = NULL,
      version = version + 1
  WHERE organization_id = p_organization_id AND id = p_draft_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_draft.confirmed_by_membership_id,
    'ai.data_entry.progressed', 'ai_data_entry_draft', p_draft_id, 'success',
    p_request_id, jsonb_build_object('status', p_status)
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_ai_data_entry_extracting_v1(
  p_event_id uuid,
  p_worker_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_draft_id uuid;
  v_organization_id uuid;
  v_status text;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 THEN
    RAISE EXCEPTION 'AI data-entry extraction claim is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT draft.id, draft.organization_id, draft.status
    INTO v_draft_id, v_organization_id, v_status
  FROM public.outbox_events AS event
  JOIN public.ai_data_entry_drafts AS draft
    ON draft.organization_id = event.organization_id
   AND draft.id::text = event.payload ->> 'draft_id'
  WHERE event.id = p_event_id
    AND event.event_type = 'ai.data_entry.requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND draft.status IN ('queued', 'extracting')
  FOR UPDATE OF draft;

  IF NOT FOUND THEN RETURN false; END IF;
  IF v_status = 'extracting' THEN RETURN true; END IF;

  UPDATE public.ai_data_entry_drafts
  SET status = 'extracting', version = version + 1, error_code = NULL
  WHERE organization_id = v_organization_id AND id = v_draft_id AND status = 'queued';
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.renew_ai_event_lease_v1(
  p_event_id uuid,
  p_worker_id text,
  p_lease_seconds integer DEFAULT 300
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_count integer;
BEGIN
  IF p_event_id IS NULL
    OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120
    OR p_lease_seconds IS NULL OR p_lease_seconds < 1 OR p_lease_seconds > 900 THEN
    RAISE EXCEPTION 'AI event lease renewal input is invalid' USING ERRCODE = '22023';
  END IF;

  UPDATE public.outbox_events AS event
  SET locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds)
  WHERE event.id = p_event_id
    AND event.event_type IN ('ai.run.requested', 'ai.data_entry.requested')
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND EXISTS (
      SELECT 1
      FROM public.ai_runs AS run
      WHERE run.organization_id = event.organization_id
        AND run.id::text = event.payload ->> 'run_id'
        AND run.status = 'running'
        AND (
          event.event_type = 'ai.run.requested'
          OR EXISTS (
            SELECT 1
            FROM public.ai_data_entry_drafts AS draft
            WHERE draft.organization_id = event.organization_id
              AND draft.id::text = event.payload ->> 'draft_id'
              AND draft.ai_run_id = run.id
              AND draft.status = 'extracting'
          )
        )
    );
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_ai_data_entry_failure_v1(
  p_event_id uuid,
  p_worker_id text,
  p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_event public.outbox_events%ROWTYPE;
  v_run public.ai_runs%ROWTYPE;
  v_draft public.ai_data_entry_drafts%ROWTYPE;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0
    OR p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$' THEN
    RAISE EXCEPTION 'AI data-entry failure input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT event.* INTO v_event
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'ai.data_entry.requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  SELECT run.* INTO v_run
  FROM public.ai_runs AS run
  WHERE run.organization_id = v_event.organization_id
    AND run.id::text = v_event.payload ->> 'run_id'
    AND run.agent_kind = 'data_entry'
    AND run.status IN ('queued', 'running', 'failed')
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = v_event.organization_id
    AND draft.id::text = v_event.payload ->> 'draft_id'
    AND draft.ai_run_id = v_run.id
    AND draft.status IN ('queued', 'extracting', 'failed')
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_run.status <> 'failed' THEN
    UPDATE public.ai_runs
    SET status = 'failed',
        finished_at = timezone('utc', now()),
        error_code = p_error_code
    WHERE organization_id = v_run.organization_id AND id = v_run.id;
  END IF;

  IF v_draft.status <> 'failed' THEN
    UPDATE public.ai_data_entry_drafts
    SET status = 'failed',
        error_code = p_error_code,
        version = version + 1
    WHERE organization_id = v_draft.organization_id AND id = v_draft.id;
  END IF;

  INSERT INTO public.notifications (
    organization_id, recipient_membership_id, category, title, body,
    resource_type, resource_id, dedupe_key
  ) VALUES (
    v_run.organization_id,
    v_run.initiated_by_membership_id,
    'system',
    'تعذر إكمال اقتراح AI',
    'تعذر تشغيل طلب الاقتراح. راجع الإعدادات أو أعد الطلب يدوياً.',
    'ai_run',
    v_run.id,
    'ai-run-failed:' || v_run.id::text || ':' || p_error_code
  ) ON CONFLICT (organization_id, dedupe_key) DO NOTHING;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.ai_data_entry_application_seed_v1(jsonb,integer[],integer[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_ai_data_entry_confirmation_v2(uuid,uuid,jsonb,integer,text,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.heartbeat_ai_data_entry_confirmation_v3(uuid,uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.heartbeat_ai_data_entry_confirmation_v3(uuid,uuid,uuid) TO service_role;

REVOKE ALL ON FUNCTION public.finalize_ai_data_entry_confirmation_v2(uuid,uuid,uuid,text,jsonb,integer,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_ai_data_entry_confirmation_v2(uuid,uuid,uuid,text,jsonb,integer,uuid) TO service_role;

REVOKE ALL ON FUNCTION public.mark_ai_data_entry_extracting_v1(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_ai_data_entry_extracting_v1(uuid,text) TO voya_outbox_worker, service_role;

REVOKE ALL ON FUNCTION public.renew_ai_event_lease_v1(uuid,text,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.renew_ai_event_lease_v1(uuid,text,integer) TO voya_outbox_worker, service_role;

REVOKE ALL ON FUNCTION public.finalize_ai_data_entry_failure_v1(uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_ai_data_entry_failure_v1(uuid,text,text) TO voya_outbox_worker, service_role;