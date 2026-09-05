-- R-01 follow-up (PR30 review): close the direct-read bypass around the
-- property RPC AAL2 wrappers.
--
-- Authenticated members can SELECT public.properties through PostgREST with
-- only an active membership, so an AAL1 session could read property rows
-- without MFA despite the RPC gate. Owner/image tables have no direct-read
-- policies at all (RPC-only), so only the properties member-read policy needs
-- the same database-owned AAL2 condition.
--
-- Application and worker reads are unaffected: pages read through SECURITY
-- DEFINER RPCs (RLS bypass) and service_role bypasses RLS entirely.

DROP POLICY IF EXISTS properties_read_member ON public.properties;

CREATE POLICY properties_read_member ON public.properties
  FOR SELECT TO authenticated
  USING (
    public.current_user_has_active_membership(organization_id)
    AND (auth.jwt() ->> 'aal') = 'aal2'
  );
