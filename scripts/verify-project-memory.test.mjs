import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
import test from "node:test";

const REPOSITORY_ROOT = resolve(new URL("..", import.meta.url).pathname);
const VERIFIER = join(REPOSITORY_ROOT, "scripts/verify-project-memory.mjs");

const MEMORY_FILES = [
  "PROJECT.md",
  "ARCHITECTURE.md",
  "DOMAIN_RULES.md",
  "DATA_MODEL.md",
  "SECURITY.md",
  "INTEGRATIONS.md",
  "SOURCES_OF_TRUTH.md",
  "CURRENT_STATE.md",
  "KNOWN_ISSUES.md",
  "GLOSSARY.md",
  "MAINTENANCE.md",
];

function runVerifier(root) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(process.execPath, [VERIFIER, "--root", root], {
      cwd: REPOSITORY_ROOT,
      env: { ...process.env, NO_COLOR: "1" },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("exit", (code, signal) => resolveResult({ code, signal, stdout, stderr }));
  });
}

async function writeFixture(mutate) {
  const root = await mkdtemp(join(tmpdir(), "voya-memory-"));
  await mkdir(join(root, "docs/memory"), { recursive: true });
  await mkdir(join(root, "docs/adr"), { recursive: true });
  await mkdir(join(root, "src"), { recursive: true });
  await mkdir(join(root, "supabase"), { recursive: true });

  await writeFile(join(root, "AGENTS.md"), "# Root contract\n\nRead [memory](docs/memory/INDEX.md).\n");
  await writeFile(join(root, "src/AGENTS.md"), "# Source contract\n\nRead [memory](../docs/memory/INDEX.md).\n");
  await writeFile(join(root, "supabase/AGENTS.md"), "# Database contract\n\nRead [memory](../docs/memory/INDEX.md).\n");

  const catalog = MEMORY_FILES.map((file) => `- [${file}](./${file})`).join("\n");
  await writeFile(
    join(root, "docs/memory/INDEX.md"),
    `# Memory index\n\n${catalog}\n`,
  );

  for (const file of MEMORY_FILES) {
    const body = file === "ARCHITECTURE.md"
      ? "# Architecture\n\n```mermaid\nflowchart LR\n  A --> B\n```\n"
      : file === "CURRENT_STATE.md"
        ? "# Current state\n\nLast verified: 2026-08-03\n"
        : `# ${file.replace(".md", "")}\n\nVerified memory.\n`;
    await writeFile(join(root, "docs/memory", file), body);
  }

  await writeFile(join(root, "docs/adr/ADR-001-test.md"), "# ADR-001 — Test\n\nAccepted.\n");
  await writeFile(join(root, "docs/adr/ADR-014-memory.md"), "# ADR-014 — Memory\n\nAccepted.\n");
  await writeFile(
    join(root, "docs/adr/INDEX.md"),
    "# ADR index\n\n- [ADR-001](./ADR-001-test.md)\n- [ADR-014](./ADR-014-memory.md)\n",
  );

  if (mutate) await mutate(root);
  return root;
}

async function withFixture(mutate, callback) {
  const root = await writeFixture(mutate);
  try {
    return await callback(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("accepts a complete memory fixture", async () => {
  await withFixture(null, async (root) => {
    const result = await runVerifier(root);
    assert.equal(result.code, 0, result.stderr || result.stdout);
  });
});

test("rejects a missing required memory document", async () => {
  await withFixture(async (root) => {
    await rm(join(root, "docs/memory/SECURITY.md"));
  }, async (root) => {
    const result = await runVerifier(root);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /SECURITY\.md/);
  });
});

test("rejects an unindexed memory document", async () => {
  await withFixture(async (root) => {
    await writeFile(join(root, "docs/memory/EXTRA.md"), "# Extra\n");
  }, async (root) => {
    const result = await runVerifier(root);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /INDEX\.md/);
  });
});

test("rejects a broken relative link", async () => {
  await withFixture(async (root) => {
    await writeFile(join(root, "docs/memory/PROJECT.md"), "# Project\n\n[missing](./does-not-exist.md)\n");
  }, async (root) => {
    const result = await runVerifier(root);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /does-not-exist\.md/);
  });
});

test("rejects a repository-escaping link", async () => {
  await withFixture(async (root) => {
    await writeFile(join(root, "docs/memory/PROJECT.md"), "# Project\n\n[escape](../../../outside.md)\n");
  }, async (root) => {
    const result = await runVerifier(root);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /escapes repository/);
  });
});

test("rejects a memory file symlink that resolves outside the repository", async () => {
  await withFixture(async (root) => {
    await rm(join(root, "docs/memory/PROJECT.md"));
    await symlink("/etc/hosts", join(root, "docs/memory/PROJECT.md"));
  }, async (root) => {
    const result = await runVerifier(root);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /outside repository|symlink/i);
  });
});

test("rejects duplicate ADR identifiers", async () => {
  await withFixture(async (root) => {
    await writeFile(join(root, "docs/adr/ADR-001-second.md"), "# ADR-001 — Duplicate\n");
  }, async (root) => {
    const result = await runVerifier(root);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /duplicate ADR identifier/i);
  });
});

test("rejects an ADR that is missing from the ADR index", async () => {
  await withFixture(async (root) => {
    await writeFile(
      join(root, "docs/adr/INDEX.md"),
      "# ADR index\n\n- [ADR-001](./ADR-001-test.md)\n",
    );
  }, async (root) => {
    const result = await runVerifier(root);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /ADR-014-memory\.md/);
  });
});

test("rejects a malformed current-state verification date", async () => {
  await withFixture(async (root) => {
    await writeFile(join(root, "docs/memory/CURRENT_STATE.md"), "# Current state\n\nLast verified: soon\n");
  }, async (root) => {
    const result = await runVerifier(root);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /Last verified/);
  });
});

test("rejects unbalanced Mermaid fences", async () => {
  await withFixture(async (root) => {
    await writeFile(join(root, "docs/memory/ARCHITECTURE.md"), "# Architecture\n\n```mermaid\nflowchart LR\nA --> B\n");
  }, async (root) => {
    const result = await runVerifier(root);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /Mermaid/);
  });
});

test("rejects an AGENTS file that does not route to the memory index", async () => {
  await withFixture(async (root) => {
    await writeFile(join(root, "src/AGENTS.md"), "# Source contract\n");
  }, async (root) => {
    const result = await runVerifier(root);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /AGENTS\.md/);
  });
});
