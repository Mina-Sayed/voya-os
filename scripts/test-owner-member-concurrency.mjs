import { execFileSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const databaseUrl = process.env.DATABASE_URL;
if (process.env.VOYA_DB_TEST !== "1" || !databaseUrl) {
  throw new Error("Refusing owner concurrency test: set VOYA_DB_TEST=1 and an explicit DATABASE_URL.");
}

const parsedUrl = new URL(databaseUrl);
const allowedHosts = new Set(["127.0.0.1", "localhost", "::1"]);
const databaseName = decodeURIComponent(parsedUrl.pathname.replace(/^\/+/, ""));
if (
  !allowedHosts.has(parsedUrl.hostname)
  || !/^[A-Za-z_][A-Za-z0-9_]*_test$/u.test(databaseName)
  || parsedUrl.search
  || parsedUrl.hash
) {
  throw new Error("Refusing owner concurrency test: use a local database whose name matches *_test.");
}

const password = decodeURIComponent(parsedUrl.password);
parsedUrl.password = "";
const safeConnectionUrl = parsedUrl.toString();
const projectRoot = fileURLToPath(new URL("../", import.meta.url));
const env = { ...process.env, PGPASSWORD: password };
const organizationId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
const firstOwner = "11111111-1111-1111-1111-111111111111";
const secondOwner = "55555555-5555-5555-5555-555555555555";

const executePsql = (sql) => execFileSync(
  "psql",
  [safeConnectionUrl, "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
  { cwd: projectRoot, env, encoding: "utf8" },
).trim();

const executePsqlAsync = (sql) => new Promise((resolve, reject) => {
  const child = spawn(
    "psql",
    [safeConnectionUrl, "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
    { cwd: projectRoot, env },
  );
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  child.on("error", reject);
  child.on("close", (code) => {
    if (code === 0) {
      resolve(stdout);
      return;
    }
    reject(new Error(`Owner concurrency writer failed with exit code ${code}: ${stderr}`));
  });
});

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

const resetOwners = () => {
  executePsql(`
    UPDATE public.organization_memberships
    SET role = 'owner', status = 'active', updated_at = timezone('utc', now())
    WHERE organization_id = '${organizationId}'
      AND user_id IN ('${firstOwner}', '${secondOwner}');
  `);
  const state = executePsql(`
    SELECT count(*)
    FROM public.organization_memberships
    WHERE organization_id = '${organizationId}'
      AND role = 'owner'
      AND status = 'active'
      AND user_id IN ('${firstOwner}', '${secondOwner}');
  `);
  if (state !== "2") {
    throw new Error(`Expected two active owner fixtures, received ${state}.`);
  }
};

const downgradeFirstOwner = () => executePsqlAsync(`
  SET ROLE authenticated;
  SELECT set_config('request.jwt.claim.sub', '${firstOwner}', false);
  BEGIN;
  SELECT public.change_organization_member_role(
    '${organizationId}',
    (SELECT id FROM public.organization_memberships
      WHERE organization_id = '${organizationId}' AND user_id = '${firstOwner}'),
    'viewer', NULL
  );
  SELECT pg_sleep(1);
  COMMIT;
`);

const mutateSecondOwner = (command) => executePsqlAsync(`
  SET ROLE authenticated;
  SELECT set_config('request.jwt.claim.sub', '${secondOwner}', false);
  BEGIN;
  SELECT public.${command}(
    '${organizationId}',
    (SELECT id FROM public.organization_memberships
      WHERE organization_id = '${organizationId}' AND user_id = '${secondOwner}'),
    'owner serialization regression', NULL
  );
  COMMIT;
`);

const runRace = async (command) => {
  resetOwners();
  const downgrade = downgradeFirstOwner();
  await delay(100);
  const lifecycleMutation = mutateSecondOwner(command);
  const results = await Promise.allSettled([downgrade, lifecycleMutation]);

  const successes = results.filter((result) => result.status === "fulfilled").length;
  const failures = results.filter((result) => result.status === "rejected").length;
  if (successes !== 1 || failures !== 1) {
    throw new Error(`Expected exactly one ${command} / downgrade writer to commit; successes=${successes}, failures=${failures}.`);
  }

  const ownerCount = executePsql(`
    SELECT count(*)
    FROM public.organization_memberships
    WHERE organization_id = '${organizationId}'
      AND role = 'owner'
      AND status = 'active';
  `);
  if (ownerCount !== "1") {
    throw new Error(`Expected one active owner after ${command} race, received ${ownerCount}.`);
  }
};

await runRace("suspend_organization_member");
await runRace("remove_organization_member");
resetOwners();

console.log("owner lifecycle serialization concurrency tests passed");
