import { describe, expect, test } from "vitest";
import { parseWhatsappPropertyConfirmation } from "./whatsapp-property-confirmation";

function formData(values: Record<string, string>) {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

const valid = {
  owner_display_name: "أحمد",
  owner_phone: "+201000000000",
  owner_whatsapp: "+201000000000",
  owner_preferred_contact_method: "whatsapp",
  code: "NASR-001",
  name: "شقة عباس العقاد",
  timezone: "Africa/Cairo",
  address: "عباس العقاد",
  city: "Nasr City",
  unit_label: "A-1",
  bedrooms: "3",
  bathrooms: "2",
  furnished: "true",
  rent_monthly: "true",
  monthly_price: "35000",
  currency: "EGP",
  ownership_start_date: "2026-08-27",
  ownership_end_date: "2099-12-31",
};

describe("WhatsApp property confirmation input", () => {
  test("normalizes a complete staff confirmation payload", () => {
    const parsed = parseWhatsappPropertyConfirmation(formData(valid));

    expect(parsed).toEqual({
      ok: true,
      value: expect.objectContaining({
        ownerDisplayName: "أحمد",
        propertyCode: "NASR-001",
        bedrooms: 3,
        bathrooms: 2,
        furnished: true,
        rentMonthly: true,
        monthlyPrice: 35000,
        currency: "EGP",
        ownershipStartDate: "2026-08-27",
        ownershipEndDate: "2099-12-31",
      }),
    });
  });

  test("rejects missing source-record identity and invalid ownership range", () => {
    const parsed = parseWhatsappPropertyConfirmation(formData({ ...valid, owner_display_name: "", code: "", ownership_start_date: "2027-01-02", ownership_end_date: "2027-01-01" }));

    expect(parsed).toEqual({ ok: false, errors: expect.arrayContaining(["owner_display_name_required", "code_required", "ownership_range_invalid"]) });
  });

  test("preserves zero and false values without accepting malformed numbers", () => {
    const parsed = parseWhatsappPropertyConfirmation(formData({ ...valid, bathrooms: "0", furnished: "false", monthly_price: "-1" }));

    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.errors).toContain("monthly_price_invalid");
  });
});
