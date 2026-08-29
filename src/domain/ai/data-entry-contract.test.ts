import { describe, expect, test } from "vitest";
import {
  canConfirmDataEntryPayload,
  isDataEntryRole,
  type DataEntryPayload,
  validateDataEntryPayload,
} from "./data-entry-contract";

const incompletePayload: DataEntryPayload = {
  clients: [
    {
      displayName: null,
      phone: null,
      whatsapp: null,
      email: null,
      nationality: null,
      preferredLanguage: null,
      notes: null,
      sourceLeadId: null,
      confidence: "low",
      missingRequired: ["display_name"],
    },
  ],
  properties: [
    {
      code: null,
      name: null,
      timezone: null,
      address: "مصر الجديدة",
      city: "القاهرة",
      unitLabel: null,
      bedrooms: null,
      maxGuests: null,
      operationalNotes: null,
      imageInputIds: ["input-image-1"],
      confidence: "medium",
      missingRequired: ["code", "name", "timezone"],
    },
  ],
  unresolved: [{ value: "150 متر", reason: "لا يوجد حقل مساحة" }],
  warnings: [],
};

describe("data-entry contract", () => {
  test("keeps missing required facts visible and blocks confirmation", () => {
    expect(canConfirmDataEntryPayload(incompletePayload)).toBe(false);
    expect(validateDataEntryPayload(incompletePayload, ["input-image-1"])).toEqual({
      ok: true,
      value: incompletePayload,
    });
  });

  test("preserves null instead of inventing values", () => {
    const result = validateDataEntryPayload(incompletePayload, []);

    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.errors).toContain("unknown_image_input");
    expect(incompletePayload.properties[0]?.bedrooms).toBeNull();
    expect(incompletePayload.clients[0]?.phone).toBeNull();
  });

  test("accepts only operational data-entry roles", () => {
    expect(isDataEntryRole("owner")).toBe(true);
    expect(isDataEntryRole("manager")).toBe(true);
    expect(isDataEntryRole("sales_agent")).toBe(true);
    expect(isDataEntryRole("operations")).toBe(true);
    expect(isDataEntryRole("accountant")).toBe(false);
    expect(isDataEntryRole("viewer")).toBe(false);
  });

  test("rejects payloads that exceed bounded record limits", () => {
    const tooManyClients = {
      ...incompletePayload,
      clients: Array.from({ length: 51 }, () => incompletePayload.clients[0]),
    };

    const result = validateDataEntryPayload(tooManyClients, ["input-image-1"]);

    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.errors).toContain("clients_limit");
  });
});
