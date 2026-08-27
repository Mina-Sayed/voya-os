import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const source = readFileSync("supabase/functions/outbox-dispatch/index.ts", "utf8");

describe("WhatsApp AI outbox worker contract", () => {
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
});
