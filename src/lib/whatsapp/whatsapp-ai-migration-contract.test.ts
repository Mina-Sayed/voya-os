import { readFileSync, readdirSync } from "node:fs";
import { describe, expect, test } from "vitest";

const migration = readFileSync("supabase/migrations/20260827153809_whatsapp_ai_agent_phase1.sql", "utf8");
const safetyRemediationMigration = readFileSync(
  "supabase/migrations/20260909012000_revoke_whatsapp_ai_legacy_result.sql",
  "utf8",
);
const openWaIngestMigrationName = readdirSync("supabase/migrations")
  .find((name) => /_add_openwa_whatsapp_ingest\.sql$/u.test(name));
const openWaIngestMigration = openWaIngestMigrationName
  ? readFileSync(`supabase/migrations/${openWaIngestMigrationName}`, "utf8")
  : "";

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
    expect(migration).not.toContain("create_property_v2");
    expect(migration).not.toContain("update_property_v2");
  });

  test("leaves only the guarded result wrapper callable by workers", () => {
    const normalizedMigration = safetyRemediationMigration.replace(/\s+/gu, "");

    expect(normalizedMigration).toContain(
      "REVOKEALLONFUNCTIONpublic.apply_whatsapp_ai_result_v1_legacy(uuid,text,text,jsonb,text,text,text,boolean)FROMPUBLIC,anon,authenticated,voya_outbox_worker,service_role;",
    );
    expect(normalizedMigration).toContain(
      "GRANTEXECUTEONFUNCTIONpublic.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)TOvoya_outbox_worker,service_role;",
    );
    expect(normalizedMigration).toContain("SETsearch_path=pg_catalog");
    expect(normalizedMigration).not.toContain(
      "GRANTEXECUTEONFUNCTIONpublic.apply_whatsapp_ai_result_v1_legacy",
    );
  });

  test("adds a globally unique OpenWA channel identity and service-role-only ingest RPC", () => {
    const normalizedMigration = openWaIngestMigration.replace(/\s+/gu, "");

    expect(openWaIngestMigrationName).toBeDefined();
    expect(normalizedMigration).toContain("CREATEUNIQUEINDEX");
    expect(normalizedMigration).toContain("WHEREprovider='openwa'");
    expect(normalizedMigration).toContain("CREATEORREPLACEFUNCTIONpublic.ingest_whatsapp_openwa_event_v1(");
    expect(normalizedMigration).toContain("RETURNSuuid");
    expect(normalizedMigration).toContain("REVOKEALLONFUNCTIONpublic.ingest_whatsapp_openwa_event_v1");
    expect(normalizedMigration).toContain("FROMPUBLIC,anon,authenticated");
    expect(normalizedMigration).toContain("GRANTEXECUTEONFUNCTIONpublic.ingest_whatsapp_openwa_event_v1");
    expect(normalizedMigration).toContain("TOservice_role");
    expect(normalizedMigration.toLowerCase()).toContain("openwa-jid:");
    expect(normalizedMigration).toContain("ELSIFp_direction='outbound'THEN");
    expect(normalizedMigration).toContain("CREATEORREPLACEFUNCTIONpublic.apply_whatsapp_ai_result_v1(");
    expect(normalizedMigration).toContain("CREATEORREPLACEFUNCTIONpublic.apply_whatsapp_ai_result_v1_legacy(");
    expect(normalizedMigration).toContain("WHENlower(v_contact.normalized_value)LIKE'openwa-jid:%'THENNULL");
    expect(normalizedMigration).toContain("crm_normalize_phone(coalesce(v_phone,v_whatsapp,v_contact_phone))");
    expect(normalizedMigration).not.toContain("crm_normalize_phone(coalesce(v_phone,v_whatsapp,v_contact.normalized_value))");
  });
});
