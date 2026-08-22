import { describe, expect, test } from "vitest";
import { validateDataEntryPayload } from "./data-entry-contract";

const client = {
  displayName: "أحمد",
  phone: null,
  whatsapp: null,
  email: null,
  nationality: null,
  preferredLanguage: null,
  notes: null,
  sourceLeadId: null,
  confidence: "high" as const,
  missingRequired: [] as string[],
};

const property = {
  code: "P-1",
  name: "شقة",
  timezone: "Africa/Cairo",
  address: null,
  city: null,
  unitLabel: null,
  bedrooms: null,
  maxGuests: null,
  operationalNotes: null,
  imageInputIds: ["input-1"],
  confidence: "high" as const,
  missingRequired: [] as string[],
};

describe("AI data-entry remediation invariants", () => {
  test("rejects assigning one intake image to multiple properties", () => {
    const result = validateDataEntryPayload({
      clients: [],
      properties: [property, { ...property, code: "P-2", imageInputIds: ["input-1"] }],
      unresolved: [],
      warnings: [],
    }, ["input-1"]);

    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.errors).toContain("duplicate_image_input");
  });

  test("matches the editable client-name limit to create_client_v1", () => {
    const result = validateDataEntryPayload({
      clients: [{ ...client, displayName: "أ".repeat(161) }],
      properties: [],
      unresolved: [],
      warnings: [],
    });

    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.errors).toContain("client_0_displayName_invalid");
  });
});
