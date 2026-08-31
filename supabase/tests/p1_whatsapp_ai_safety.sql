-- P1 regression checks for WhatsApp AI and auth rate-limit safety.

DO $$
DECLARE
  v_source text;
BEGIN
  SELECT pg_get_functiondef(
    'public.renew_whatsapp_ai_event_lease_v1(uuid,text,integer)'::regprocedure
  ) INTO v_source;

  IF position('channel.kill_switch = false' IN v_source) = 0
    OR position('channel.status = ''active''' IN v_source) = 0 THEN
    RAISE EXCEPTION 'WhatsApp AI lease renewal must enforce channel kill switch and active status';
  END IF;

  SELECT pg_get_functiondef(
    'public.start_whatsapp_ai_run_v1(uuid,text,text,text)'::regprocedure
  ) INTO v_source;

  IF position('channel.kill_switch = false' IN v_source) = 0
    OR position('channel.status = ''active''' IN v_source) = 0 THEN
    RAISE EXCEPTION 'WhatsApp AI run start must enforce channel kill switch and active status';
  END IF;

  SELECT pg_get_functiondef(
    'public.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)'::regprocedure
  ) INTO v_source;

  IF position('p_confidence <> ''low''' IN v_source) = 0
    OR position('channel.kill_switch = false' IN v_source) = 0 THEN
    RAISE EXCEPTION 'WhatsApp AI result boundary must enforce low-confidence and channel safety';
  END IF;
END;
$$;

DO $$
BEGIN
  IF to_regprocedure('public.consume_auth_rate_limit(text,text,integer,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'legacy caller-configurable auth rate-limit overload must not exist';
  END IF;

  IF to_regprocedure('public.consume_auth_rate_limit(text,text)') IS NULL THEN
    RAISE EXCEPTION 'database-owned two-argument auth rate-limit function is missing';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.consume_auth_rate_limit(text,text)',
    'EXECUTE'
  ) IS NOT TRUE
  OR has_function_privilege(
    'authenticated',
    'public.consume_auth_rate_limit(text,text)',
    'EXECUTE'
  ) IS NOT TRUE THEN
    RAISE EXCEPTION 'pre-auth rate-limit function must remain callable by anon/authenticated';
  END IF;
END;
$$;
