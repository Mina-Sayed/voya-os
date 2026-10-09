import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import { webcrypto } from "node:crypto";
import ts from "typescript";
import { describe, expect, it, vi } from "vitest";
import { failOutboxDeliveryEvent, failWhatsappAiOutboxEvent } from "./failure-terminalization";
import { dispatchOutboxEvent } from "./dispatch-contract";
import { sendOpenWaWithAttemptGuard } from "./openwa-send-attempt";
import { storePendingWhatsappImageForWorker } from "../whatsapp/whatsapp-ai-worker";
import { MetaWhatsAppMediaError } from "../whatsapp/meta-media";
import { OpenWaWhatsAppMediaError } from "../whatsapp/openwa-media";

// Execute the Edge worker's actual functions with infrastructure collaborators
// supplied locally. Deno.serve is captured without starting a server or calling
// a live messaging/model provider.
function loadWorker(dependencies: Record<string, unknown> = {}) {
  const source = readFileSync("supabase/functions/outbox-dispatch/index.ts", "utf8");
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  const exports: Record<string, (...args: unknown[]) => Promise<unknown>> = {};
  runInNewContext(`${compiled}\nObject.assign(exports, { retryWhatsappAiEvent, processInBatches, executeWhatsappMediaEvent });`, {
    exports,
    require: (name: string) => dependencies[name] ?? dependencies[name.split("/").at(-1) ?? name] ?? (name.endsWith("/failure-terminalization.ts")
      ? { failOutboxDeliveryEvent, failWhatsappAiOutboxEvent }
      : {}),
    Deno: { serve: (handler: (...args: unknown[]) => Promise<unknown>) => { exports.handleRequest = handler; }, env: { toObject: () => ({}) } },
    crypto: webcrypto, Response, TextEncoder, TextDecoder, atob,
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

const mediaContext = {
  organization_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  conversation_id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  message_id: "cccccccc-cccc-cccc-cccc-cccccccccccc",
  media_status: "pending", channel_enabled: true, provider: "openwa",
  provider_channel_id: "session", chat_id: "201000000000@c.us",
  provider_media_id: "provider-image", mime_type_hint: "image/jpeg",
};
const mediaEvent = { id: "media-event", attempts: 1 };
const mediaConfig = { openWaApiBaseUrl: "https://gateway.example.test", openWaApiKey: "synthetic-key" };

function mediaWorker(download: ReturnType<typeof vi.fn>) {
  const createGeminiProvider = vi.fn(() => { throw new Error("Media intake must not invoke Gemini"); });
  const createMetaWhatsAppMediaAdapter = vi.fn(() => ({ download: vi.fn() }));
  const bytesToBase64 = vi.fn(() => { throw new Error("Media-only intake must not encode model parts"); });
  const worker = loadWorker({
    "openwa-media.ts": { createOpenWaMediaAdapter: () => ({ download }), OpenWaWhatsAppMediaError },
    "meta-media.ts": { createMetaWhatsAppMediaAdapter, MetaWhatsAppMediaError },
    "whatsapp-ai-worker.ts": { storePendingWhatsappImageForWorker },
    "gemini-runtime.ts": { createGeminiProvider },
    "data-entry-worker.ts": { bytesToBase64 },
  });
  return { worker, createGeminiProvider, createMetaWhatsAppMediaAdapter, bytesToBase64 };
}

describe("executed private WhatsApp media intake", () => {
  it("stores a phone image independently of AI without constructing model image parts", async () => {
    const download = vi.fn().mockResolvedValue({ mimeType: "image/jpeg", sizeBytes: 3, bytes: new Uint8Array([255, 216, 255]) });
    const { worker, createGeminiProvider, createMetaWhatsAppMediaAdapter, bytesToBase64 } = mediaWorker(download);
    const rpc = vi.fn(async (name: string) => ({ data: name === "resolve_whatsapp_media_intake_v1" ? [mediaContext] : true, error: null }));
    const upload = vi.fn().mockResolvedValue({ error: null });
    const storage = { from: vi.fn(() => ({ upload })) };

    await expect(worker.executeWhatsappMediaEvent({ rpc, storage }, mediaEvent, "worker", mediaConfig)).resolves.toBe("completed");
    expect(download).toHaveBeenCalledExactlyOnceWith({ sessionId: "session", chatId: mediaContext.chat_id, messageId: "provider-image", mimeTypeHint: "image/jpeg" });
    expect(rpc.mock.calls.map(([name]) => name)).toEqual([
      "resolve_whatsapp_media_intake_v1", "renew_whatsapp_media_event_lease_v1",
      "renew_whatsapp_media_event_lease_v1", "store_whatsapp_media_v1", "complete_outbox_event",
    ]);
    expect(storage.from).toHaveBeenCalledWith("ai-intake");
    expect(upload.mock.calls[0][2]).toEqual({ contentType: "image/jpeg", upsert: false });
    expect(createGeminiProvider).not.toHaveBeenCalled();
    expect(createMetaWhatsAppMediaAdapter).not.toHaveBeenCalled();
    expect(bytesToBase64).not.toHaveBeenCalled();
  });

  it.each(["stored", "failed"])("completes an already %s media retry without another provider download", async (mediaStatus) => {
    const download = vi.fn();
    const { worker } = mediaWorker(download);
    const rpc = vi.fn(async (name: string) => ({ data: name === "resolve_whatsapp_media_intake_v1" ? [{ ...mediaContext, media_status: mediaStatus }] : true, error: null }));
    await expect(worker.executeWhatsappMediaEvent({ rpc }, mediaEvent, "worker", mediaConfig)).resolves.toBe("completed");
    expect(download).not.toHaveBeenCalled();
    expect(rpc.mock.calls.map(([name]) => name)).toEqual(["resolve_whatsapp_media_intake_v1", "complete_outbox_event"]);
  });

  it("terminalizes a disabled-channel intake through the atomic media failure RPC", async () => {
    const download = vi.fn();
    const { worker } = mediaWorker(download);
    const rpc = vi.fn(async (name: string) => ({ data: name === "resolve_whatsapp_media_intake_v1" ? [{ ...mediaContext, channel_enabled: false }] : "dead_letter", error: null }));
    await expect(worker.executeWhatsappMediaEvent({ rpc }, mediaEvent, "worker", mediaConfig)).resolves.toBe("failed");
    expect(download).not.toHaveBeenCalled();
    expect(rpc).toHaveBeenCalledWith("fail_whatsapp_media_event_v1", expect.objectContaining({ p_error_code: "whatsapp_media_channel_disabled", p_max_attempts: 1 }));
  });

  it.each([["retry_wait", "retry"], ["completed", "completed"]])("handles a download failure followed by atomic state %s", async (state, outcome) => {
    const download = vi.fn().mockRejectedValue(new OpenWaWhatsAppMediaError("whatsapp_media_timeout"));
    const { worker } = mediaWorker(download);
    const rpc = vi.fn(async (name: string) => ({ data: name === "resolve_whatsapp_media_intake_v1" ? [mediaContext] : name === "fail_whatsapp_media_event_v1" ? state : true, error: null }));
    await expect(worker.executeWhatsappMediaEvent({ rpc }, mediaEvent, "worker", mediaConfig)).resolves.toBe(outcome);
    expect(rpc).toHaveBeenCalledWith("fail_whatsapp_media_event_v1", expect.objectContaining({ p_error_code: "whatsapp_media_timeout", p_max_attempts: 6 }));
  });
});

describe("executed worker provider dispatch", () => {
  it("routes OpenWA through the durable attempt guard and V2 marker inside bounded claiming", async () => {
    const row = { id: "message-event", event_type: "whatsapp.message.send_requested", schema_version: 1, attempts: 1, payload: {} };
    let claims = 0;
    const callOrder: string[] = [];
    const rpc = vi.fn(async (name: string) => {
      callOrder.push(name);
      if (name === "start_outbox_worker_run") return { data: "worker-run", error: null };
      if (name === "claim_outbox_delivery_events") return { data: claims++ === 0 ? [row] : [], error: null };
      if (name === "resolve_whatsapp_outbox_delivery_v2") return { data: [{ provider: "openwa", provider_channel_id: "session", chat_id: "201000000000@c.us", body_text: "Synthetic message" }], error: null };
      return { data: true, error: null };
    });
    const send = vi.fn(async () => { callOrder.push("provider.send"); return { kind: "delivered" as const, providerMessageId: "provider-message" }; });
    const worker = loadWorker({
      "npm:@supabase/supabase-js@2": { createClient: () => ({ rpc }) },
      "dispatch-contract.ts": { dispatchOutboxEvent }, "openwa-send-attempt.ts": { sendOpenWaWithAttemptGuard },
      "worker-config.ts": { readOutboxWorkerConfig: () => ({ ...mediaConfig, openWaEnabled: true, whatsappEnabled: true }), authorizeOutboxWorkerRequest: () => true },
      "openwa-outbound.ts": { createOpenWaOutboundAdapter: () => ({ send }) },
    });
    const response = await worker.handleRequest(new Request("https://worker.example.test", { method: "POST" })) as Response;
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ claimed: 1, completed: 1, needs_review: 0 });
    expect(send).toHaveBeenCalledExactlyOnceWith({ provider: "openwa", sessionId: "session", chatId: "201000000000@c.us", body: "Synthetic message", idempotencyKey: "message-event" });
    expect(callOrder.indexOf("renew_outbox_delivery_lease_v1")).toBeLessThan(callOrder.indexOf("begin_openwa_send_attempt_v1"));
    expect(callOrder.indexOf("begin_openwa_send_attempt_v1")).toBeLessThan(callOrder.indexOf("provider.send"));
    expect(callOrder.indexOf("provider.send")).toBeLessThan(callOrder.indexOf("mark_whatsapp_message_sent_v2"));
    expect(callOrder).not.toContain("clear_openwa_send_attempt_v1");
    expect(rpc).toHaveBeenCalledWith("claim_outbox_delivery_events", expect.objectContaining({ p_limit: 5, p_lease_seconds: 900 }));
  });
});
