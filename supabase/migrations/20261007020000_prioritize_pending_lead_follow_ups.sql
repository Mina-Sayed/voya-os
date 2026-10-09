-- The lead detail batch is bounded to ten follow-ups. Completed history must
-- not consume that window before pending tasks can be displayed/completed.
DO $migration$
DECLARE v_definition text;
BEGIN
  SELECT pg_get_functiondef('public.list_lead_page_details_v1(uuid,uuid[])'::regprocedure)
  INTO v_definition;
  IF strpos(v_definition, 'ORDER BY (follow_up.status = ''pending'') DESC') > 0 THEN
    RETURN;
  END IF;
  IF strpos(v_definition, 'ORDER BY follow_up.due_at, follow_up.id') = 0
    OR strpos(v_definition, 'PERFORM public.require_workspace_aal2_v1()') = 0
    OR strpos(v_definition, 'public.crm_sales_lead_scope_allows_v1(') = 0 THEN
    RAISE EXCEPTION 'lead detail batch changed unexpectedly before pending-task ordering';
  END IF;
  EXECUTE replace(v_definition,
    'ORDER BY follow_up.due_at, follow_up.id',
    'ORDER BY (follow_up.status = ''pending'') DESC, follow_up.due_at, follow_up.id');
END;
$migration$;

REVOKE ALL ON FUNCTION public.list_lead_page_details_v1(uuid, uuid[])
  FROM PUBLIC, anon, service_role, voya_outbox_worker;
GRANT EXECUTE ON FUNCTION public.list_lead_page_details_v1(uuid, uuid[]) TO authenticated;
