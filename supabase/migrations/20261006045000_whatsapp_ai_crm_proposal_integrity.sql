-- Track AI-created WhatsApp lead intake as unverified until an authenticated
-- staff update records human review.
ALTER TABLE public.leads
  ADD COLUMN IF NOT EXISTS ai_unverified boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.mark_whatsapp_ai_lead_review_state_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, auth
AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.source = 'whatsapp'
    AND NEW.idempotency_key LIKE 'whatsapp-conversation:%' THEN
    NEW.ai_unverified := true;
  ELSIF TG_OP = 'UPDATE' AND OLD.ai_unverified AND auth.uid() IS NOT NULL THEN
    NEW.ai_unverified := false;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.mark_whatsapp_ai_lead_review_state_v1() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS leads_whatsapp_ai_review_state ON public.leads;
CREATE TRIGGER leads_whatsapp_ai_review_state
  BEFORE INSERT OR UPDATE ON public.leads
  FOR EACH ROW EXECUTE FUNCTION public.mark_whatsapp_ai_lead_review_state_v1();

-- Keep the validated extractor output in conversation.structured_state as a
-- proposal, and only project high-confidence values into blank CRM fields.
-- Build from the immediately preceding implementation so unrelated reply,
-- handoff, and run-lifecycle behavior stays intact. If upstream SQL changed,
-- fail this migration instead of silently skipping a guard.
DO $migration$
DECLARE
  v_definition text;
  v_old text[] := ARRAY[
    'title = coalesce(v_lead_name, title)',
    'name = coalesce(v_lead_name, name)',
    'phone = coalesce(v_phone, phone)',
    'whatsapp = coalesce(v_whatsapp, whatsapp)',
    'email = coalesce(v_email, email)',
    'normalized_phone = coalesce(v_normalized_phone, normalized_phone)',
    'normalized_email = coalesce(v_normalized_email, normalized_email)',
    'requested_area = coalesce(v_requested_area, requested_area)',
    'requested_check_in = coalesce(v_check_in, requested_check_in)',
    'requested_check_out = coalesce(v_check_out, requested_check_out)',
    'guests = coalesce(v_guests, guests)',
    'bedrooms = coalesce(v_bedrooms, bedrooms)',
    'budget_text = coalesce(v_budget_text, budget_text)',
    'notes = coalesce(v_notes, notes)',
    'next_follow_up_at = coalesce(v_next_follow_up_at, next_follow_up_at)',
    'v_qualified := v_requested_area IS NOT NULL',
    'v_lead_status := CASE WHEN v_qualified THEN ''qualified'' ELSE ''new'' END;',
    'status = CASE WHEN status = ''new'' AND v_qualified THEN ''qualified'' ELSE status END'
  ];
  v_new text[] := ARRAY[
    'title = CASE WHEN p_confidence = ''high'' AND title LIKE ''WhatsApp %'' THEN coalesce(v_lead_name, title) ELSE title END',
    'name = coalesce(name, CASE WHEN p_confidence = ''high'' THEN v_lead_name END)',
    'phone = coalesce(phone, CASE WHEN p_confidence = ''high'' THEN v_phone END)',
    'whatsapp = coalesce(whatsapp, CASE WHEN p_confidence = ''high'' THEN v_whatsapp END)',
    'email = coalesce(email, CASE WHEN p_confidence = ''high'' THEN v_email END)',
    'normalized_phone = coalesce(normalized_phone, public.crm_normalize_phone(coalesce(phone, whatsapp)), CASE WHEN p_confidence = ''high'' THEN v_normalized_phone END)',
    'normalized_email = coalesce(normalized_email, public.crm_normalize_email(email), CASE WHEN p_confidence = ''high'' THEN v_normalized_email END)',
    'requested_area = coalesce(requested_area, CASE WHEN p_confidence = ''high'' THEN v_requested_area END)',
    'requested_check_in = coalesce(requested_check_in, CASE WHEN p_confidence = ''high'' THEN v_check_in END)',
    'requested_check_out = coalesce(requested_check_out, CASE WHEN p_confidence = ''high'' THEN v_check_out END)',
    'guests = coalesce(guests, CASE WHEN p_confidence = ''high'' THEN v_guests END)',
    'bedrooms = coalesce(bedrooms, CASE WHEN p_confidence = ''high'' THEN v_bedrooms END)',
    'budget_text = coalesce(budget_text, CASE WHEN p_confidence = ''high'' THEN v_budget_text END)',
    'notes = coalesce(notes, CASE WHEN p_confidence = ''high'' THEN v_notes END)',
    'next_follow_up_at = coalesce(next_follow_up_at, CASE WHEN p_confidence = ''high'' THEN v_next_follow_up_at END)',
    $qualified$
IF p_confidence = 'low' THEN
    v_lead_name := NULL;
    v_phone := NULL;
    v_whatsapp := NULL;
    v_email := NULL;
    v_normalized_phone := public.crm_normalize_phone(v_contact.normalized_value);
    v_normalized_email := NULL;
    v_requested_area := NULL;
    v_check_in := NULL;
    v_check_out := NULL;
    v_guests := NULL;
    v_bedrooms := NULL;
    v_budget_text := NULL;
    v_notes := NULL;
    v_next_follow_up_at := NULL;
  END IF;
  v_qualified := v_requested_area IS NOT NULL$qualified$,
    'v_lead_status := ''new'';',
    'status = status'
  ];
  v_index integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.apply_whatsapp_ai_result_v1_legacy(uuid,text,text,jsonb,text,text,text,boolean)'::regprocedure
  ) INTO v_definition;
  IF v_definition IS NULL THEN
    RAISE EXCEPTION 'WhatsApp AI result function is missing';
  END IF;
  FOR v_index IN 1..array_length(v_old, 1) LOOP
    IF pg_catalog.strpos(v_definition, v_old[v_index]) = 0 THEN
      RAISE EXCEPTION 'WhatsApp AI CRM projection changed unexpectedly at replacement %', v_index;
    END IF;
    v_definition := pg_catalog.replace(v_definition, v_old[v_index], v_new[v_index]);
  END LOOP;
  EXECUTE v_definition;
END;
$migration$;
