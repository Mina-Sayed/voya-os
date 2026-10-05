-- PUBLIC inherits EXECUTE on PostgreSQL functions by default. Remove any
-- remaining inherited grants and prevent future public-schema functions from
-- acquiring them automatically. Existing explicit role grants are preserved.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
