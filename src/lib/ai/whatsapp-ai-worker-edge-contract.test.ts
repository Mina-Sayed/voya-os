import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const source = readFileSync("supabase/functions/outbox-dispatch/index.ts", "utf8");
const workerSource = readFileSync("src/lib/whatsapp/whatsapp-ai-worker.ts", "utf8");

describe("WhatsApp AI outbox worker contract", () => {
  test("keeps the explicit-extension compatibility suppression valid for Deno and TypeScript", () => {
    expect(workerSource).not.toMatch(/@ts-(?:expect-)?ignore/u);
  });

  test("claims and executes the WhatsApp AI event through the existing worker", () => {
    expect(source).toContain("whatsapp.ai.respond_requested");
    expect(source).toContain("resolve_whatsapp_ai_execution_v1");
    expect(source).toContain("apply_whatsapp_ai_result_v1");
    expect(source).toContain("createMetaWhatsAppMediaAdapter");
    expect(source).toContain("parseWhatsappAiResponse");
    expect(source).toContain("completeLeasedEvent");
  });

  test("keeps media retrieval and AI calls behind lease revalidation", () => {
    const media = source.indexOf("createMetaWhatsAppMediaAdapter");
    const generate = source.indexOf("provider.generate", media);
    expect(media).toBeGreaterThanOrEqual(0);
    expect(generate).toBeGreaterThan(media);
    expect(source.indexOf("renew_whatsapp_ai_event_lease_v1", media)).toBeGreaterThanOrEqual(0);
  });

  test("finalizes the exhausted event and AI run through one database command", () => {
    expect(source).toContain("failWhatsappAiOutboxEvent(");
    expect(source).not.toContain('p_error_code: "whatsapp_ai_retry_exhausted"');
  });

  test("processes claimed deliveries in bounded concurrent batches with renew-able leases", () => {
    expect(source).toContain("const PROCESSING_CONCURRENCY = 5;");
    expect(source).toContain("const LEASE_SECONDS = 900;");
    expect(source).toContain("const WORKER_MAX_BATCH_RUNTIME_MS = 60_000;");
    expect(source).toContain("await processInBatches(claimedBatch, PROCESSING_CONCURRENCY");
    expect(source).toContain("Promise.allSettled(batch.map(processItem))");
    expect(source).toContain("p_limit: Math.min(PROCESSING_CONCURRENCY");
    expect(source).toContain("Date.now() - invocationStartedAt + WORKER_MAX_BATCH_RUNTIME_MS < WORKER_INVOCATION_BUDGET_MS");
    expect(source).toContain("renewOutboxDeliveryLease(client, row.id, workerId)");
  });
});
