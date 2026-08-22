import { describe, expect, test } from "vitest";
import { parseDataEntryPayload, parseEditableDataEntryPayload } from "./data-entry-payload";

const validJson = JSON.stringify({
  clients: [
    {
      display_name: "  أحمد  ",
      phone: null,
      whatsapp: null,
      email: "ahmed@example.com",
      nationality: null,
      preferred_language: "ar",
      notes: null,
      source_lead_id: null,
      confidence: "high",
      missing_required: [],
    },
  ],
  properties: [],
  unresolved: [],
  warnings: [],
});

describe("parseDataEntryPayload", () => {
  test("normalizes schema keys and trims text", () => {
    const result = parseDataEntryPayload(validJson);

    expect(result).toEqual({
      ok: true,
      value: expect.objectContaining({
        clients: [expect.objectContaining({ displayName: "أحمد", email: "ahmed@example.com" })],
      }),
    });
  });

  test("rejects malformed or truncated JSON before any write path", () => {
    expect(parseDataEntryPayload('{"clients":[{"display_name":"أحمد"')).toEqual({
      ok: false,
      errors: ["invalid_json"],
    });
  });

  test("rejects unknown action-bearing keys and untrusted image references", () => {
    const result = parseDataEntryPayload(JSON.stringify({
      clients: [],
      properties: [{
        code: null,
        name: "شقة",
        timezone: "Africa/Cairo",
        address: null,
        city: null,
        unit_label: null,
        bedrooms: null,
        max_guests: null,
        operational_notes: null,
        image_input_ids: ["foreign-input"],
        confidence: "medium",
        missing_required: [],
        execute_sql: "drop table clients",
      }],
      unresolved: [],
      warnings: [],
    }), ["local-input"]);

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors).toContain("unknown_property_key");
      expect(result.errors).toContain("unknown_image_input");
    }
  });

  test("rejects oversized source payloads", () => {
    const result = parseDataEntryPayload("x".repeat(20_001));

    expect(result).toEqual({ ok: false, errors: ["payload_too_large"] });
  });

  test("accepts edited camelCase payloads but rejects executable extra fields", () => {
    const result = parseEditableDataEntryPayload({
      clients: [],
      properties: [],
      unresolved: [],
      warnings: [],
      execute: "create_client",
    });

    expect(result).toEqual({ ok: false, errors: ["unknown_payload_key"] });
  });
});
