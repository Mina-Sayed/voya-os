CREATE TABLE public.leads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  title text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 160),
  source text NOT NULL CHECK (source ~ '^[a-z][a-z0-9_-]{0,63}$'),
  status text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'qualified', 'lost', 'converted')),
  requested_check_in date,
  requested_check_out date,
  assigned_membership_id uuid,
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) > 0),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT leads_requested_stay_valid CHECK ((requested_check_in IS NULL AND requested_check_out IS NULL) OR (requested_check_in < requested_check_out)),
  CONSTRAINT leads_assignee_in_organization_fk FOREIGN KEY (organization_id, assigned_membership_id) REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT leads_idempotency_key_unique UNIQUE (organization_id, idempotency_key)
);
CREATE INDEX leads_organization_status_created_idx ON public.leads (organization_id, status, created_at DESC);
CREATE INDEX leads_assignee_created_idx ON public.leads (organization_id, assigned_membership_id, created_at DESC);
CREATE TRIGGER leads_set_updated_at BEFORE UPDATE ON public.leads FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
ALTER TABLE public.leads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leads FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.leads FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.create_lead(p_organization_id uuid, p_title text, p_source text, p_status text, p_requested_check_in date, p_requested_check_out date, p_assigned_membership_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_actor uuid; v_lead public.leads%ROWTYPE; v_id uuid;
BEGIN
  SELECT id INTO v_actor FROM public.organization_memberships WHERE organization_id=p_organization_id AND user_id=auth.uid() AND status='active' AND role IN ('owner','manager','sales_agent');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'lead creation is not permitted' USING ERRCODE='42501'; END IF;
  IF p_title IS NULL OR char_length(btrim(p_title)) NOT BETWEEN 1 AND 160 OR p_source IS NULL OR p_source !~ '^[a-z][a-z0-9_-]{0,63}$' OR p_status NOT IN ('new','qualified','lost','converted') OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key))=0 OR ((p_requested_check_in IS NULL) <> (p_requested_check_out IS NULL)) OR (p_requested_check_in IS NOT NULL AND p_requested_check_in >= p_requested_check_out) THEN RAISE EXCEPTION 'lead input is invalid' USING ERRCODE='22023'; END IF;
  IF p_assigned_membership_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.organization_memberships WHERE id=p_assigned_membership_id AND organization_id=p_organization_id AND status='active') THEN RAISE EXCEPTION 'lead assignee is invalid' USING ERRCODE='23503'; END IF;
  SELECT * INTO v_lead FROM public.leads WHERE organization_id=p_organization_id AND idempotency_key=p_idempotency_key;
  IF FOUND THEN IF v_lead.title=p_title AND v_lead.source=p_source AND v_lead.status=p_status AND v_lead.requested_check_in IS NOT DISTINCT FROM p_requested_check_in AND v_lead.requested_check_out IS NOT DISTINCT FROM p_requested_check_out AND v_lead.assigned_membership_id IS NOT DISTINCT FROM p_assigned_membership_id THEN RETURN v_lead.id; END IF; RAISE EXCEPTION 'idempotency key belongs to a different lead' USING ERRCODE='23505'; END IF;
  INSERT INTO public.leads(organization_id,title,source,status,requested_check_in,requested_check_out,assigned_membership_id,idempotency_key) VALUES(p_organization_id,btrim(p_title),p_source,p_status,p_requested_check_in,p_requested_check_out,p_assigned_membership_id,p_idempotency_key) RETURNING id INTO v_id;
  INSERT INTO public.audit_events(organization_id,actor_type,actor_membership_id,action,resource_type,resource_id,outcome,request_id,after_delta) VALUES(p_organization_id,'user',v_actor,'lead.created','lead',v_id,'success',p_request_id,jsonb_build_object('title',btrim(p_title),'source',p_source,'status',p_status));
  INSERT INTO public.outbox_events(organization_id,event_type,schema_version,dedupe_key,payload) VALUES(p_organization_id,'lead.created',1,'lead:'||v_id::text,jsonb_build_object('lead_id',v_id));
  RETURN v_id;
END; $$;
CREATE OR REPLACE FUNCTION public.list_leads(p_organization_id uuid) RETURNS TABLE(id uuid,title text,source text,status text,requested_check_in date,requested_check_out date,assigned_membership_id uuid,created_at timestamptz) LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_role text; v_member uuid;
BEGIN SELECT role,id INTO v_role,v_member FROM public.organization_memberships WHERE organization_id=p_organization_id AND user_id=auth.uid() AND status='active'; IF v_role NOT IN ('owner','manager','sales_agent') THEN RAISE EXCEPTION 'lead read is not permitted' USING ERRCODE='42501'; END IF; RETURN QUERY SELECT l.id,l.title,l.source,l.status,l.requested_check_in,l.requested_check_out,l.assigned_membership_id,l.created_at FROM public.leads l WHERE l.organization_id=p_organization_id AND (v_role IN ('owner','manager') OR l.assigned_membership_id IS NULL OR l.assigned_membership_id=v_member) ORDER BY l.created_at DESC,l.id DESC; END; $$;
REVOKE ALL ON FUNCTION public.create_lead(uuid,text,text,text,date,date,uuid,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_leads(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_lead(uuid,text,text,text,date,date,uuid,text,uuid), public.list_leads(uuid) TO authenticated;
