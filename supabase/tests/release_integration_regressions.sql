-- Cross-branch upgrade: an immutable PR77 command remains replayable after
-- later edits and after PR79 installs its additional authorization wrapper.
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO public.leads (
  id, organization_id, title, name, phone, source, status, idempotency_key
) VALUES (
  'aaaaaaaa-0000-0000-0000-00000000f701',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Integration lead', 'Integration lead',
  '+201000009701', 'website', 'new', 'integration-upgrade-lead'
);
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aal":"aal2"}', true);

-- Model commands that committed on the PR77 head before PR79's request-binding
-- table existed. The private RPC is called only by the disposable test owner.
SELECT public.update_lead_v1_without_workspace_aal2(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-00000000f701',
  'First accepted name', '+201000009701', NULL, NULL, 'website', 'new', NULL,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1, 'integration-first-update', NULL
);
SELECT public.update_lead_v1_without_workspace_aal2(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-00000000f701',
  'Later accepted name', '+201000009701', NULL, NULL, 'website', 'contacted', NULL,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 2, 'integration-second-update', NULL
);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  IF NOT public.update_lead_v1(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-00000000f701',
    'First accepted name', '+201000009701', NULL, NULL, 'website', 'new', NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1, 'integration-first-update', NULL
  ) THEN
    RAISE EXCEPTION 'immutable pre-integration CRM replay did not return success';
  END IF;
  BEGIN
    PERFORM public.update_lead_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-00000000f701',
      'Reused key with different name', '+201000009701', NULL, NULL, 'website', 'new', NULL,
      NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1, 'integration-first-update', NULL
    );
    RAISE EXCEPTION 'changed immutable CRM replay unexpectedly succeeded';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END;
$$;
RESET ROLE;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.leads WHERE id = 'aaaaaaaa-0000-0000-0000-00000000f701'
      AND name = 'Later accepted name' AND status = 'contacted' AND version = 3
  ) THEN
    RAISE EXCEPTION 'CRM replay overwrote a later accepted edit';
  END IF;
  IF has_function_privilege('authenticated', 'public.list_clients_v1_before_release_integration(uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.list_clients_v1_before_release_integration(uuid)', 'EXECUTE')
    OR has_function_privilege('service_role', 'public.list_clients_v1_before_release_integration(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'clients read bridge exposed a private implementation';
  END IF;
END;
$$;
-- Completed history must not displace the next actionable task from the
-- bounded detail response consumed by the lead page.
INSERT INTO public.crm_follow_ups (
  organization_id, lead_id, due_at, note, status, completed_at,
  completed_by_membership_id, idempotency_key
)
SELECT 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-00000000f701',
  '2026-01-01'::timestamptz + n * interval '1 day', 'Historical completed task',
  'completed', '2026-02-01'::timestamptz, membership.id,
  'integration-completed-follow-up-' || n
FROM generate_series(1, 10) AS n
CROSS JOIN public.organization_memberships AS membership
WHERE membership.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND membership.user_id = '11111111-1111-1111-1111-111111111111';
INSERT INTO public.crm_follow_ups (
  id, organization_id, lead_id, due_at, note, idempotency_key
) VALUES (
  'aaaaaaaa-0000-0000-0000-00000000f702',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-00000000f701', '2026-03-01', 'Next pending task',
  'integration-pending-follow-up'
);
SET LOCAL ROLE authenticated;
DO $$
DECLARE v_follow_ups jsonb;
BEGIN
  SELECT follow_ups INTO v_follow_ups
  FROM public.list_lead_page_details_v1(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    ARRAY['aaaaaaaa-0000-0000-0000-00000000f701']::uuid[]
  );
  IF jsonb_array_length(v_follow_ups) <> 10 OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_follow_ups) AS item
    WHERE item ->> 'id' = 'aaaaaaaa-0000-0000-0000-00000000f702'
      AND item ->> 'status' = 'pending'
  ) THEN
    RAISE EXCEPTION 'completed history hid the pending task from bounded lead details';
  END IF;
END;
$$;
RESET ROLE;
ROLLBACK;
SELECT 'release integration regressions passed' AS result;
