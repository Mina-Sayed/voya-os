-- Final PR #8 recovery hardening for human-confirmed AI data entry.
--
-- A stale confirmed execution may be reclaimed only with the exact same human
-- payload and exclusions. Trusted per-item progress is persisted under the
-- execution token without advancing the operator-facing version. Active
-- confirmation ownership remains valid past the original intake expiry, every
-- trusted helper locks draft before inputs, rejection is review-state-only, and
-- data-entry needs-review events participate in workspace observability.

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
  v_expected_excluded_clients integer[];
  v_expected_excluded_properties integer[];
  v_requested_excluded_clients integer[];
  v_requested_excluded_properties integer[];
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

  -- Expiry prevents a first confirmation, but never strands a confirmation or
  -- partial recovery that already owns source-of-record side effects.
  IF v_draft.status = 'ready_for_review' AND v_draft.expires_at <= timezone('utc', now()) THEN
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

  IF v_draft.status = 'confirmed' THEN
    IF v_draft.confirmation_payload IS DISTINCT FROM p_confirmation_payload THEN
      RAISE EXCEPTION 'confirmation payload changed during recovery' USING ERRCODE = '40001';
    END IF;

    SELECT coalesce(array_agg(item_index ORDER BY item_index), ARRAY[]::integer[])
      INTO v_expected_excluded_clients
    FROM (
      SELECT (item ->> 'index')::integer AS item_index
      FROM jsonb_array_elements(
        CASE WHEN jsonb_typeof(coalesce(v_draft.application_result -> 'clients', '[]'::jsonb)) = 'array'
          THEN coalesce(v_draft.application_result -> 'clients', '[]'::jsonb) ELSE '[]'::jsonb END
      ) AS result(item)
      WHERE item ->> 'errorCode' = 'excluded_by_operator'
        AND coalesce(item ->> 'index', '') ~ '^[0-9]+$'
    ) AS excluded;
    SELECT coalesce(array_agg(item_index ORDER BY item_index), ARRAY[]::integer[])
      INTO v_expected_excluded_properties
    FROM (
      SELECT (item ->> 'index')::integer AS item_index
      FROM jsonb_array_elements(
        CASE WHEN jsonb_typeof(coalesce(v_draft.application_result -> 'properties', '[]'::jsonb)) = 'array'
          THEN coalesce(v_draft.application_result -> 'properties', '[]'::jsonb) ELSE '[]'::jsonb END
      ) AS result(item)
      WHERE item ->> 'errorCode' = 'excluded_by_operator'
        AND coalesce(item ->> 'index', '') ~ '^[0-9]+$'
    ) AS excluded;
    SELECT coalesce(array_agg(index_value ORDER BY index_value), ARRAY[]::integer[])
      INTO v_requested_excluded_clients FROM unnest(p_excluded_client_indexes) AS requested(index_value);
    SELECT coalesce(array_agg(index_value ORDER BY index_value), ARRAY[]::integer[])
      INTO v_requested_excluded_properties FROM unnest(p_excluded_property_indexes) AS requested(index_value);

    IF v_expected_excluded_clients IS DISTINCT FROM v_requested_excluded_clients
      OR v_expected_excluded_properties IS DISTINCT FROM v_requested_excluded_properties THEN
      RAISE EXCEPTION 'confirmation payload changed during recovery' USING ERRCODE = '40001';
    END IF;

    -- Preserve every durable exclusion/success from the interrupted execution.
    v_seed := coalesce(v_draft.application_result, jsonb_build_object('clients', '[]'::jsonb, 'properties', '[]'::jsonb, 'images', '[]'::jsonb));
  ELSE
    v_seed := public.ai_data_entry_application_seed_v1(
      v_draft.application_result,
      p_excluded_client_indexes,
      p_excluded_property_indexes
    );
  END IF;

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
      'excluded_properties', cardinality(p_excluded_property_indexes),
      'recovery', v_draft.status = 'confirmed'
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
    AND draft.confirmation_execution_token = p_execution_token;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.persist_ai_data_entry_confirmation_progress_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_execution_token uuid,
  p_application_result jsonb,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_draft public.ai_data_entry_drafts%ROWTYPE;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_execution_token IS NULL
    OR p_application_result IS NULL OR jsonb_typeof(p_application_result) <> 'object'
    OR jsonb_typeof(p_application_result -> 'clients') <> 'array'
    OR jsonb_typeof(p_application_result -> 'properties') <> 'array'
    OR jsonb_typeof(p_application_result -> 'images') <> 'array'
    OR char_length(p_application_result::text) > 20000 THEN
    RAISE EXCEPTION 'AI data-entry trusted incremental progress input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.id = p_draft_id
  FOR UPDATE;
  IF NOT FOUND OR v_draft.status <> 'confirmed'
    OR v_draft.confirmation_execution_token IS DISTINCT FROM p_execution_token THEN
    RETURN false;
  END IF;

  UPDATE public.ai_data_entry_drafts AS draft
  SET application_result = p_application_result,
      confirmation_execution_heartbeat_at = timezone('utc', now())
  WHERE draft.organization_id = p_organization_id
    AND draft.id = p_draft_id
    AND draft.status = 'confirmed'
    AND draft.confirmation_execution_token = p_execution_token;
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_ai_data_entry_input_mapped_v2(
  p_organization_id uuid,
  p_input_id uuid,
  p_property_id uuid,
  p_property_image_id uuid,
  p_execution_token uuid,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_input public.ai_data_entry_inputs%ROWTYPE;
  v_actor uuid;
  v_draft_id uuid;
BEGIN
  IF p_organization_id IS NULL OR p_input_id IS NULL OR p_property_id IS NULL
    OR p_property_image_id IS NULL OR p_execution_token IS NULL THEN
    RAISE EXCEPTION 'AI data-entry trusted image mapping input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT input.draft_id INTO v_draft_id
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id AND input.id = p_input_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI data-entry image mapping claim is stale' USING ERRCODE = '40001';
  END IF;

  -- Match every cleanup path: draft lock first, then deterministic input lock.
  SELECT draft.confirmed_by_membership_id INTO v_actor
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.id = v_draft_id
    AND draft.status = 'confirmed'
    AND draft.confirmation_execution_token = p_execution_token
  FOR UPDATE;
  IF NOT FOUND OR v_actor IS NULL THEN
    RAISE EXCEPTION 'AI data-entry image mapping claim is stale' USING ERRCODE = '40001';
  END IF;

  SELECT input.* INTO v_input
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.id = p_input_id
    AND input.draft_id = v_draft_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI data-entry image mapping claim is stale' USING ERRCODE = '40001';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.property_images AS image
    WHERE image.organization_id = p_organization_id AND image.id = p_property_image_id
      AND image.property_id = p_property_id AND image.status = 'active'
  ) THEN
    RAISE EXCEPTION 'registered property image is missing' USING ERRCODE = '23503';
  END IF;
  IF v_input.status = 'mapped' THEN
    IF v_input.mapped_property_id = p_property_id THEN RETURN true; END IF;
    RAISE EXCEPTION 'AI data-entry input is already mapped' USING ERRCODE = '40001';
  END IF;
  IF v_input.status <> 'active' THEN
    RAISE EXCEPTION 'AI data-entry input is unavailable' USING ERRCODE = '40001';
  END IF;

  UPDATE public.ai_data_entry_inputs
  SET status = 'mapped', mapped_property_id = p_property_id, mapped_at = timezone('utc', now())
  WHERE organization_id = p_organization_id AND id = p_input_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.input.mapped', 'ai_data_entry_input', p_input_id, 'success', p_request_id,
    jsonb_build_object('property_id', p_property_id, 'property_image_id', p_property_image_id)
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_ai_data_entry_inputs_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_input_ids uuid[],
  p_execution_token uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_found integer;
  v_updated integer;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_input_ids IS NULL
    OR p_execution_token IS NULL OR cardinality(p_input_ids) > 100
    OR cardinality(p_input_ids) <> (
      SELECT count(DISTINCT input_id)::integer
      FROM unnest(p_input_ids) AS requested(input_id)
    ) THEN
    RAISE EXCEPTION 'AI data-entry input archive request is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT draft.confirmed_by_membership_id INTO v_actor
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.id = p_draft_id
    AND draft.status = 'confirmed'
    AND draft.confirmation_execution_token = p_execution_token
  FOR UPDATE;
  IF NOT FOUND OR v_actor IS NULL THEN
    RAISE EXCEPTION 'AI data-entry input archive claim is stale' USING ERRCODE = '40001';
  END IF;

  IF cardinality(p_input_ids) = 0 THEN RETURN true; END IF;

  PERFORM 1
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = p_draft_id
    AND input.id = ANY (p_input_ids)
    AND input.status IN ('active', 'archived')
  ORDER BY input.id
  FOR UPDATE;

  SELECT count(*)::integer INTO v_found
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = p_draft_id
    AND input.id = ANY (p_input_ids)
    AND input.status IN ('active', 'archived');
  IF v_found <> cardinality(p_input_ids) THEN
    RAISE EXCEPTION 'AI data-entry input archive set is stale' USING ERRCODE = '40001';
  END IF;

  UPDATE public.ai_data_entry_inputs AS input
  SET status = 'archived'
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = p_draft_id
    AND input.id = ANY (p_input_ids)
    AND input.status = 'active';
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated > 0 THEN
    INSERT INTO public.audit_events (
      organization_id, actor_type, actor_membership_id, action, resource_type,
      resource_id, outcome, after_delta
    ) VALUES (
      p_organization_id, 'user', v_actor, 'ai.data_entry.inputs.archived',
      'ai_data_entry_draft', p_draft_id, 'success',
      jsonb_build_object('input_count', v_updated)
    );
  END IF;
  RETURN true;
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
DECLARE
  v_actor uuid;
  v_role text;
  v_draft public.ai_data_entry_drafts%ROWTYPE;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI data-entry rejection input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'AI data-entry rejection is not permitted' USING ERRCODE = '42501';
  END IF;
  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id AND draft.id = p_draft_id
    AND (v_role IN ('owner', 'manager') OR draft.created_by_membership_id = v_actor)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'AI data-entry draft is not permitted' USING ERRCODE = '42501';
  END IF;

  IF v_draft.status = 'rejected' AND v_draft.rejection_idempotency_key = btrim(p_idempotency_key) THEN
    RETURN true;
  END IF;
  IF v_draft.status <> 'ready_for_review' OR v_draft.version <> p_expected_version THEN
    RAISE EXCEPTION 'AI data-entry draft cannot be discarded' USING ERRCODE = '40001';
  END IF;

  UPDATE public.ai_data_entry_drafts
  SET status = 'rejected', rejection_idempotency_key = btrim(p_idempotency_key), version = version + 1
  WHERE organization_id = p_organization_id AND id = p_draft_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.data_entry.rejected', 'ai_data_entry_draft', p_draft_id, 'success', p_request_id,
    jsonb_build_object('status', 'rejected')
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_system_health_v1(
  p_organization_id uuid
)
RETURNS TABLE (
  database_status text,
  last_worker_run_at timestamptz,
  last_worker_status text,
  pending_outbox_count bigint,
  oldest_due_event_at timestamptz,
  dead_letter_count bigint,
  email_failure_count bigint,
  whatsapp_failure_count bigint,
  ai_failure_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_role text;
BEGIN
  SELECT membership.role INTO v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'system health read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    'ok'::text,
    coalesce(worker.finished_at, worker.started_at),
    worker.status,
    (SELECT count(*) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.state IN ('pending', 'retry_wait', 'processing')),
    (SELECT min(event.available_at) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.state IN ('pending', 'retry_wait') AND event.available_at <= timezone('utc', now())),
    (SELECT count(*) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.state = 'dead_letter'),
    (SELECT count(*) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.event_type IN ('organization.invitation.send_requested', 'member.invitation.resent') AND event.state IN ('dead_letter', 'needs_review')),
    (SELECT count(*) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.event_type = 'whatsapp.message.send_requested' AND event.state IN ('dead_letter', 'needs_review')),
    (
      SELECT count(*)
      FROM public.ai_runs AS run
      WHERE run.organization_id = p_organization_id
        AND (
          run.status = 'failed'
          OR EXISTS (
            SELECT 1 FROM public.outbox_events AS event
            WHERE event.organization_id = p_organization_id
              AND event.event_type IN ('ai.run.requested', 'ai.data_entry.requested')
              AND event.state IN ('dead_letter', 'needs_review')
              AND event.payload ->> 'run_id' = run.id::text
          )
        )
    )
  FROM (
    SELECT run.started_at, run.finished_at, run.status
    FROM public.outbox_worker_runs AS run
    ORDER BY run.started_at DESC, run.id DESC
    LIMIT 1
  ) AS worker;

  IF NOT FOUND THEN
    RETURN QUERY SELECT
      'ok'::text, NULL::timestamptz, NULL::text,
      (SELECT count(*) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.state IN ('pending', 'retry_wait', 'processing')),
      (SELECT min(event.available_at) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.state IN ('pending', 'retry_wait') AND event.available_at <= timezone('utc', now())),
      (SELECT count(*) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.state = 'dead_letter'),
      (SELECT count(*) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.event_type IN ('organization.invitation.send_requested', 'member.invitation.resent') AND event.state IN ('dead_letter', 'needs_review')),
      (SELECT count(*) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.event_type = 'whatsapp.message.send_requested' AND event.state IN ('dead_letter', 'needs_review')),
      (
        SELECT count(*)
        FROM public.ai_runs AS run
        WHERE run.organization_id = p_organization_id
          AND (
            run.status = 'failed'
            OR EXISTS (
              SELECT 1 FROM public.outbox_events AS event
              WHERE event.organization_id = p_organization_id
                AND event.event_type IN ('ai.run.requested', 'ai.data_entry.requested')
                AND event.state IN ('dead_letter', 'needs_review')
                AND event.payload ->> 'run_id' = run.id::text
            )
          )
      );
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_outbox_delivery_failure()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_title text;
  v_body text;
BEGIN
  IF OLD.state IS NOT DISTINCT FROM NEW.state
    OR NEW.state NOT IN ('dead_letter', 'needs_review')
    OR NEW.event_type NOT IN (
      'organization.invitation.send_requested',
      'member.invitation.resent',
      'whatsapp.message.send_requested',
      'ai.data_entry.requested'
    ) THEN
    RETURN NEW;
  END IF;

  IF NEW.event_type = 'ai.data_entry.requested' THEN
    v_title := CASE NEW.state WHEN 'dead_letter' THEN 'فشل إدخال البيانات الذكي' ELSE 'إدخال بيانات ذكي يحتاج مراجعة' END;
    v_body := 'تعذر إكمال معالجة مسودة إدخال البيانات تلقائياً. راجع حالة المسودة والتشغيل قبل إعادة المحاولة.';
  ELSE
    v_title := CASE NEW.state WHEN 'dead_letter' THEN 'فشل تسليم خارجي' ELSE 'تسليم خارجي يحتاج مراجعة' END;
    v_body := CASE NEW.event_type
      WHEN 'whatsapp.message.send_requested' THEN 'تعذر تسليم رسالة WhatsApp خارجية. راجع الحالة من صندوق WhatsApp قبل إعادة المحاولة.'
      ELSE 'تعذر تسليم دعوة عضو بالبريد. راجع حالة الدعوة قبل إعادة الإرسال.'
    END;
  END IF;

  INSERT INTO public.notifications (
    organization_id, recipient_membership_id, category, title, body,
    resource_type, resource_id, dedupe_key
  )
  SELECT NEW.organization_id,
    membership.id,
    'system',
    v_title,
    v_body,
    'outbox_event',
    NEW.id,
    'outbox-delivery-failure:' || NEW.id::text || ':' || NEW.state || ':' || coalesce(NEW.last_error_code, 'unknown') || ':' || membership.id::text
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = NEW.organization_id
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager')
  ON CONFLICT (organization_id, dedupe_key) DO NOTHING;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.heartbeat_ai_data_entry_confirmation_v3(uuid,uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.heartbeat_ai_data_entry_confirmation_v3(uuid,uuid,uuid) TO service_role;

REVOKE ALL ON FUNCTION public.persist_ai_data_entry_confirmation_progress_v1(uuid,uuid,uuid,jsonb,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.persist_ai_data_entry_confirmation_progress_v1(uuid,uuid,uuid,jsonb,uuid) TO service_role;

REVOKE ALL ON FUNCTION public.mark_ai_data_entry_input_mapped_v2(uuid,uuid,uuid,uuid,uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_ai_data_entry_input_mapped_v2(uuid,uuid,uuid,uuid,uuid,uuid) TO service_role;

REVOKE ALL ON FUNCTION public.archive_ai_data_entry_inputs_v1(uuid,uuid,uuid[],uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.archive_ai_data_entry_inputs_v1(uuid,uuid,uuid[],uuid) TO service_role;

REVOKE ALL ON FUNCTION public.reject_ai_data_entry_draft_v1(uuid,uuid,integer,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reject_ai_data_entry_draft_v1(uuid,uuid,integer,text,uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.notify_outbox_delivery_failure() FROM PUBLIC, anon, authenticated;
