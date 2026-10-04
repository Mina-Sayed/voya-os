import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import ts from "typescript";
import { expect, test, vi } from "vitest";

// Run the actual Edge worker function with local infrastructure collaborators.
const worker = readFileSync("supabase/functions/outbox-dispatch/index.ts", "utf8");
const syntax = ts.createSourceFile("worker.ts", worker, ts.ScriptTarget.ES2022, true);
const declaration = syntax.statements.find((node) => ts.isFunctionDeclaration(node) && node.name?.text === "executeWhatsappMediaEvent");
if (!declaration) throw new Error("Media worker missing");
const javascript = ts.transpileModule(declaration.getText(syntax), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
}).outputText;

test.each(["completed", "retry_wait", "dead_letter"])("settles a peer storage race with %s", async (state) => {
  const storeImage = vi.fn().mockRejectedValue(new Error("provider unavailable"));
  const needsReview = vi.fn();
  const execute = runInNewContext(`${javascript}; executeWhatsappMediaEvent`, {
    storePendingWhatsappImageForWorker: storeImage,
    createOpenWaMediaAdapter: vi.fn(),
    whatsappErrorCode: () => "whatsapp_media_provider_unavailable",
    whatsappErrorIsRetryable: () => true,
    getAiRetryDelay: () => 30,
    MAX_ATTEMPTS: 6,
    markNeedsReview: needsReview,
    sha256Hex: vi.fn(), bytesToBase64: vi.fn(),
  });
  const rpc = vi.fn(async (name: string) => ({ error: null, data: name === "resolve_whatsapp_media_intake_v1"
    ? [{ message_id: "message", media_status: "pending", provider: "openwa", channel_enabled: true }]
    : state }));
  expect(await execute({ rpc }, { id: "event", attempts: 1 }, "worker", {}))
    .toBe(state === "completed" ? "completed" : state === "retry_wait" ? "retry" : "failed");
  expect(storeImage).toHaveBeenCalledOnce();
  expect(needsReview).not.toHaveBeenCalled();
});
