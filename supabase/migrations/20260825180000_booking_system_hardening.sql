-- Voya OS: booking system hardening.
-- Forward-only by design: legacy migrations may already be applied remotely.
-- Commercial V1 is the supported booking write surface; legacy booking write
-- commands must not remain callable by application roles.

REVOKE ALL ON FUNCTION public.create_booking_draft(
  uuid, uuid, uuid, date, date, text, uuid
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.request_booking_approval(
  uuid, uuid, text, uuid
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.confirm_booking(
  uuid, uuid, text, uuid
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.record_booking_stay_event(
  uuid, uuid, text, text, text, uuid
) FROM PUBLIC, anon, authenticated;
