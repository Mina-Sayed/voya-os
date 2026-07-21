import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const databaseUrl = process.env.DATABASE_URL;

if (process.env.VOYA_DB_TEST !== "1" || !databaseUrl) {
  throw new Error("Refusing database test: set VOYA_DB_TEST=1 and an explicit DATABASE_URL.");
}

const parsedUrl = new URL(databaseUrl);
const allowedHosts = new Set(["127.0.0.1", "localhost", "::1"]);

if (!allowedHosts.has(parsedUrl.hostname) || !parsedUrl.pathname.endsWith("_test")) {
  throw new Error("Refusing database test: use a local database whose name ends in _test.");
}

const password = decodeURIComponent(parsedUrl.password);
parsedUrl.password = "";
const safeConnectionUrl = parsedUrl.toString();
const projectRoot = fileURLToPath(new URL("../", import.meta.url));
const executePsql = (args) => {
  execFileSync("psql", [safeConnectionUrl, "-v", "ON_ERROR_STOP=1", ...args], {
    cwd: projectRoot,
    env: { ...process.env, PGPASSWORD: password },
    stdio: "inherit",
  });
};

executePsql(["-c", "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"]);
executePsql(["-f", "supabase/tests/bootstrap_auth.sql"]);
executePsql(["-f", "supabase/migrations/20260721000100_tenancy_booking_foundation.sql"]);
executePsql(["-f", "supabase/tests/tenancy_booking_foundation.sql"]);
