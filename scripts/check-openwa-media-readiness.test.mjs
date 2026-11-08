import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { validateOpenWaMediaReadiness } from "./check-openwa-media-readiness.mjs";

const gatewayExample = fileURLToPath(new URL("../infra/openwa/gateway.env.example", import.meta.url));
const validConfig = [
  "MEDIA_DOWNLOAD_ENABLED=true",
  "CHAT_MEDIA_ARCHIVE_ENABLED=true",
  "VOYA_AUTOMATION_OWNER=true",
  "WEBHOOK_MEDIA_INLINE_MAX_BYTES=0",
  "STORAGE_TYPE=local",
  "STORAGE_LOCAL_PATH=./data/media",
].join("\n");

test("checked-in dedicated gateway example can persist inbound media", () => {
  assert.deepEqual(validateOpenWaMediaReadiness(readFileSync(gatewayExample, "utf8")), []);
});

test("rejects a gateway that downloads but does not archive media", () => {
  const issues = validateOpenWaMediaReadiness(validConfig.replace("CHAT_MEDIA_ARCHIVE_ENABLED=true", "CHAT_MEDIA_ARCHIVE_ENABLED=false"));
  assert.match(issues.join("\n"), /CHAT_MEDIA_ARCHIVE_ENABLED/);
});

test("rejects a gateway that cannot download media", () => {
  assert.match(validateOpenWaMediaReadiness(validConfig.replace("MEDIA_DOWNLOAD_ENABLED=true", "MEDIA_DOWNLOAD_ENABLED=false")).join("\n"), /MEDIA_DOWNLOAD_ENABLED/);
});

test("does not allow media embedded in webhook payloads", () => {
  assert.match(validateOpenWaMediaReadiness(validConfig.replace("WEBHOOK_MEDIA_INLINE_MAX_BYTES=0", "WEBHOOK_MEDIA_INLINE_MAX_BYTES=1048576")).join("\n"), /WEBHOOK_MEDIA_INLINE_MAX_BYTES/);
});

test("detects duplicate critical keys rather than allowing ambiguous overrides", () => {
  assert.match(validateOpenWaMediaReadiness(`${validConfig}\nCHAT_MEDIA_ARCHIVE_ENABLED=false`).join("\n"), /defined more than once/);
});

test("requires a dedicated VOYA gateway owner", () => {
  assert.match(validateOpenWaMediaReadiness(validConfig.replace("VOYA_AUTOMATION_OWNER=true", "VOYA_AUTOMATION_OWNER=false")).join("\n"), /VOYA_AUTOMATION_OWNER/);
});
