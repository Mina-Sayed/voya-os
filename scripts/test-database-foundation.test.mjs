import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const projectRoot = new URL("../", import.meta.url);

test("applies every migration transactionally and runs the hardening tests", () => {
  const fakeBin = mkdtempSync(join(tmpdir(), "voya-db-harness-"));
  const psqlLog = join(fakeBin, "psql.log");
  const psqlEnvironmentLog = join(fakeBin, "psql-environment.log");
  const fakePsql = join(fakeBin, "psql");

  writeFileSync(fakePsql, `#!/bin/sh
printf '%s\\n' "$*" >> "$VOYA_PSQL_LOG"
printf '%s\\n' "\${PGHOSTADDR-}" >> "$VOYA_PSQL_ENV_LOG"
case "$*" in
  *"INSERT INTO public.availability_blocks"*)
    printf 'simulated occupancy exclusion violation\\n' >&2
    exit 1
    ;;
esac
for argument in "$@"; do
  if [ "$argument" = "-At" ]; then
    printf '1\\n'
  fi
  if [ "$argument" = "-Atq" ]; then
    printf 'dddddddd-1111-1111-1111-111111111111\\n'
  fi
done
`);
  chmodSync(fakePsql, 0o755);

  try {
    const result = spawnSync(process.execPath, ["scripts/test-database-foundation.mjs"], {
      cwd: projectRoot,
      env: {
        ...process.env,
        DATABASE_URL: "postgresql://postgres:postgres@127.0.0.1:5432/voya_test",
        PATH: `${fakeBin}:${process.env.PATH ?? ""}`,
        VOYA_DB_TEST: "1",
        VOYA_PSQL_LOG: psqlLog,
        VOYA_PSQL_ENV_LOG: psqlEnvironmentLog,
        PGHOSTADDR: "198.51.100.25",
      },
      encoding: "utf8",
    });

    assert.equal(result.status, 0, result.stderr);
    const invocations = readFileSync(psqlLog, "utf8").split("\n").filter(Boolean);
    const migrations = invocations.filter((line) => line.includes("-f supabase/migrations/"));

    assert.ok(migrations.length > 0, "expected the harness to apply migrations");
    assert.ok(
      migrations.every((line) => line.includes("--single-transaction")),
      "every migration must be applied with psql --single-transaction",
    );

    const dependencyBootstrap = migrations.findIndex((line) =>
      line.includes("20260721000000_bootstrap_runtime_dependencies.sql"),
    );
    const workerLifecycle = migrations.findIndex((line) =>
      line.includes("20260801000700_outbox_worker_lifecycle.sql"),
    );
    assert.ok(dependencyBootstrap >= 0, "expected the runtime dependency bootstrap migration");
    assert.ok(dependencyBootstrap < workerLifecycle, "worker role bootstrap must precede worker grants");

    assert.ok(
      invocations.some((line) => line.includes("-f supabase/tests/auth_bootstrap_security.sql")),
      "expected auth bootstrap security coverage",
    );
    assert.ok(
      invocations.some((line) => line.includes("-f supabase/tests/command_idempotency.sql")),
      "expected command idempotency coverage",
    );
    assert.equal(
      invocations.some((line) => line.includes("DROP ROLE")),
      false,
      "the harness must not drop a cluster-global role",
    );
    assert.ok(existsSync(psqlEnvironmentLog), "expected psql environment evidence");
    assert.equal(
      readFileSync(psqlEnvironmentLog, "utf8").split("\n").filter(Boolean).length,
      0,
      "inherited libpq routing variables must not reach psql",
    );

    const unsafeLog = join(fakeBin, "unsafe-psql.log");
    const unsafeResult = spawnSync(process.execPath, ["scripts/test-database-foundation.mjs"], {
      cwd: projectRoot,
      env: {
        ...process.env,
        DATABASE_URL: "postgresql://postgres:postgres@127.0.0.1:5432/voya_test?hostaddr=198.51.100.1",
        PATH: `${fakeBin}:${process.env.PATH ?? ""}`,
        VOYA_DB_TEST: "1",
        VOYA_PSQL_LOG: unsafeLog,
        VOYA_PSQL_ENV_LOG: join(fakeBin, "unsafe-psql-environment.log"),
        PGHOSTADDR: "198.51.100.25",
      },
      encoding: "utf8",
    });
    assert.notEqual(unsafeResult.status, 0, "URI routing parameters must be rejected before psql runs");
    assert.equal(existsSync(unsafeLog), false, "unsafe database URI must not reach psql");
  } finally {
    rmSync(fakeBin, { recursive: true, force: true });
  }
});
