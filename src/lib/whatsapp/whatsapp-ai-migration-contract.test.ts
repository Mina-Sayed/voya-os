import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const migration = readFileSync("supabase/migrations/20260827153809_whatsapp_ai_agent_phase1.sql", "utf8");

describe("WhatsApp AI Phase 1 database contract", () => {
  test("declares tenant-scoped conversation state, media ingest, and worker projection boundaries", () => {
    expect(migration).toContain("ALTER TABLE public.whatsapp_conversations");
    expect(migration).toContain("ai_enabled");
    expect(migration).toContain("structured_state");
    expect(migration).toContain("CREATE OR REPLACE FUNCTION public.ingest_whatsapp_webhook_event_v1");
    expect(migration).toContain("CREATE OR REPLACE FUNCTION public.resolve_whatsapp_ai_execution_v1");
    expect(migration).toContain("CREATE OR REPLACE FUNCTION public.apply_whatsapp_ai_result_v1");
    expect(migration).toContain("whatsapp.ai.respond_requested");
  });

  test("keeps worker commands off browser roles and carries furnished-rental fields", () => {
    expect(migration).toContain("REVOKE ALL ON FUNCTION public.ingest_whatsapp_webhook_event_v1");
    expect(migration).toContain("TO service_role");
    expect(migration).toContain("bathrooms");
    expect(migration).toContain("district");
    expect(migration).toContain("rent_daily");
    expect(migration).toContain("daily_price");
  });
});
