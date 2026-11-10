import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

/**
 * Checks only the minimum OpenWA settings required for VOYA's inbound-image flow.
 * This does not verify a running gateway, durable disk, retention, or permissions.
 */
export function validateOpenWaMediaReadiness(contents) {
  const config = new Map();
  const issues = [];
  for (const [index, line] of contents.split(/\r?\n/u).entries()) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const match = /^(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=\s*(.*)$/u.exec(trimmed);
    if (!match) continue;
    const key = match[1];
    if (config.has(key)) {
      issues.push(`${key} is defined more than once (line ${index + 1}).`);
      continue;
    }
    let value = match[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    } else {
      value = value.replace(/\s+#.*$/u, "").trim();
    }
    config.set(key, value);
  }

  for (const key of ["MEDIA_DOWNLOAD_ENABLED", "CHAT_MEDIA_ARCHIVE_ENABLED", "VOYA_AUTOMATION_OWNER"]) {
    if (config.get(key) !== "true") issues.push(`${key} must be true for VOYA inbound-media readiness.`);
  }
  if (config.get("WEBHOOK_MEDIA_INLINE_MAX_BYTES") !== "0") {
    issues.push("WEBHOOK_MEDIA_INLINE_MAX_BYTES must be 0: media is fetched privately, not embedded into webhook payloads.");
  }
  // Upstream defaults the omitted storage type to local. Reject implicit fallback
  // instead of certifying a potentially ephemeral container-relative archive.
  const storageType = config.get("STORAGE_TYPE");
  if (storageType === undefined) {
    issues.push("STORAGE_TYPE must be set explicitly for media archive readiness.");
  } else if (storageType !== "local" && storageType !== "s3") {
    issues.push("STORAGE_TYPE must be local or s3.");
  }
  if ((storageType === "local" || storageType === undefined) && !config.get("STORAGE_LOCAL_PATH")?.trim()) {
    issues.push("STORAGE_LOCAL_PATH must be configured for local media archives.");
  }
  return issues;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  const file = process.argv[2];
  if (!file || process.argv.length !== 3) {
    console.error("Usage: node scripts/check-openwa-media-readiness.mjs <gateway-env-file>");
    process.exitCode = 2;
  } else {
    try {
      const issues = validateOpenWaMediaReadiness(readFileSync(file, "utf8"));
      if (issues.length) {
        for (const issue of issues) console.error(`OpenWA media preflight: ${issue}`);
        process.exitCode = 1;
      } else {
        console.log("OpenWA media preflight passed (configuration only; live delivery and retention not verified).");
      }
    } catch {
      // Never log .env file contents or sensitive values.
      console.error("OpenWA media preflight: unable to read the specified environment file.");
      process.exitCode = 2;
    }
  }
}
