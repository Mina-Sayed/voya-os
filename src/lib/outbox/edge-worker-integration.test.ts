import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import ts from "typescript";
import { describe, expect, it, vi } from "vitest";
import { failOutboxDeliveryEvent, failWhatsappAiOutboxEvent } from "./failure-terminalization";

// Execute the Edge worker's actual functions with infrastructure collaborators
// supplied locally. Deno.serve is captured without starting a server or calling
// a live messaging/model provider.
function loadWorker(dependencies: Record<string, unknown> = {}) {
  const source = readFileSync("supabase/functions/outbox-dispatch/index.ts", "utf8");
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  const exports: Record<string, (...args: unknown[]) => Promise<unknown>> = {};
  runInNewContext(`${compiled}\nObject.assign(exports, { retryWhatsappAiEvent, processInBatches });`, {
    exports,
    require: (name: string) => dependencies[name] ?? (name.endsWith("/failure-terminalization.ts")
      ? { failOutboxDeliveryEvent, failWhatsappAiOutboxEvent }
      : {}),
    Deno: { serve: vi.fn() },
  });
  return exports;
}

describe("executed Edge worker integration", () => {
  it("exhausts a WhatsApp AI retry through the atomic run/event command", async () => {
    const worker = loadWorker();
    const rpc = vi.fn().mockResolvedValue({ data: "dead_letter", error: null });

    await expect(worker.retryWhatsappAiEvent(
      { rpc }, { id: "ai-event", attempts: 6 }, "worker", "provider_failed",
    )).resolves.toBe("failed");
    expect(rpc).toHaveBeenCalledExactlyOnceWith("fail_whatsapp_ai_outbox_event_v1", {
      p_event_id: "ai-event", p_worker_id: "worker", p_error_code: "provider_failed",
      p_retry_after_seconds: 21600, p_max_attempts: 6,
    });
  });

  it("quarantines a failed atomic transition without issuing a split terminal update", async () => {
    const worker = loadWorker();
    const rpc = vi.fn(async (name: string) => name === "fail_whatsapp_ai_outbox_event_v1"
      ? { data: null, error: { code: "40001" } }
      : { data: true, error: null });

    await expect(worker.retryWhatsappAiEvent(
      { rpc }, { id: "ai-event", attempts: 6 }, "worker", "provider_failed",
    )).resolves.toBe("needs_review");
    expect(rpc.mock.calls.map(([name]) => name)).toEqual([
      "fail_whatsapp_ai_outbox_event_v1", "mark_outbox_event_needs_review",
    ]);
  });

  it("limits simultaneously executing deliveries and drains a failed batch before stopping", async () => {
    const worker = loadWorker();
    let active = 0;
    let maximumActive = 0;
    const attempted: number[] = [];
    const finished: number[] = [];
    const processItem = async (item: number) => {
      attempted.push(item);
      active += 1;
      maximumActive = Math.max(active, maximumActive);
      await Promise.resolve();
      active -= 1;
      finished.push(item);
      if (item === 2) throw new Error("delivery failed");
    };

    await expect(worker.processInBatches([1, 2, 3, 4, 5, 6], 5, processItem)).rejects.toThrow("delivery failed");
    expect(maximumActive).toBe(5);
    expect(attempted).toEqual([1, 2, 3, 4, 5]);
    expect(finished).toEqual(attempted);
    expect(active).toBe(0);
  });
});
