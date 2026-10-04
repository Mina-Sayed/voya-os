import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const upstream = "https://github.com/rmyndharis/OpenWA.git";
const revision = "bc206c28c6ab5baad5d68d15bb116c4b06e8d855";
const patch = join(dirname(fileURLToPath(import.meta.url)), "individual-chats.patch");
const digest = createHash("sha256").update(readFileSync(patch)).digest("hex");
const image = `voya-openwa:${revision.slice(0, 8)}-${digest.slice(0, 12)}`;
const checkOnly = process.argv.includes("--check");
const checkout = mkdtempSync(join(tmpdir(), "voya-openwa-build-"));

function run(command, args) {
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status}).`);
}

try {
  run("git", ["init", "--quiet", checkout]);
  run("git", ["-C", checkout, "remote", "add", "origin", upstream]);
  run("git", ["-C", checkout, "fetch", "--quiet", "--depth=1", "origin", revision]);
  run("git", ["-C", checkout, "checkout", "--quiet", "--detach", "FETCH_HEAD"]);
  run("git", ["-C", checkout, "apply", "--check", patch]);
  run("git", ["-C", checkout, "apply", patch]);
  run(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), "../../scripts/test-openwa-event-privacy.mjs"), checkout]);
  console.log(`Verified OpenWA source ${revision}; patch SHA256 ${digest}.`);
  if (!checkOnly) run("docker", ["build", "--tag", image, checkout]);
  console.log(`${checkOnly ? "Build target" : "Built image"}: ${image}`);
} finally {
  rmSync(checkout, { recursive: true, force: true });
}
