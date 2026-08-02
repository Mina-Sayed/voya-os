DO $$
BEGIN
  IF NOT has_function_privilege('authenticated', 'public.list_booking_drafts(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must execute the booking draft read function';
  END IF;
  IF has_function_privilege('anon', 'public.list_booking_drafts(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute the booking draft read function';
  END IF;
END;
$$;
