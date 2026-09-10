import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { PropertyEditForm } from "./property-edit-form";

const action = vi.fn().mockResolvedValue({ status: "success", message: "تم الحفظ." });

const property = {
  id: "property-legacy",
  code: "LEGACY-1",
  name: "عقار قديم",
  timezone: "America/Toronto",
  address: null,
  city: null,
  unitLabel: null,
  bedrooms: 2,
  maxGuests: 4,
  operationalNotes: null,
  dailyPrice: 100.125,
  weeklyPrice: null,
  monthlyPrice: 35000.125,
  currency: "XYZ",
  status: "active" as const,
  version: 7,
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:00.000Z",
  archivedAt: null,
  currentPropertyOwnerName: null,
  imageCount: 0,
  imageIds: [],
};

describe("PropertyEditForm money/timezone recovery", () => {
  it("keeps unsupported legacy currency and timezone selected until the operator explicitly changes them", () => {
    render(<PropertyEditForm property={property} updateProperty={action} />);

    expect(screen.getByRole<HTMLSelectElement>("combobox", { name: "المنطقة الزمنية" }).value).toBe("America/Toronto");
    expect(screen.getByRole("option", { name: /America\/Toronto.*قيمة قديمة/u })).toBeInTheDocument();
    expect(screen.getByRole<HTMLSelectElement>("combobox", { name: "العملة" }).value).toBe("XYZ");
    expect(screen.getByRole("option", { name: /XYZ.*قيمة قديمة/u })).toBeInTheDocument();
  });

  it("updates property price steps when the selected currency precision changes", () => {
    render(<PropertyEditForm property={{ ...property, timezone: "Africa/Cairo", currency: "JPY", dailyPrice: 100 }} updateProperty={action} />);

    const dailyPrice = screen.getByRole("spinbutton", { name: "السعر اليومي" });
    const currency = screen.getByRole("combobox", { name: "العملة" });
    expect(dailyPrice).toHaveAttribute("step", "1");

    fireEvent.change(currency, { target: { value: "KWD" } });
    expect(dailyPrice).toHaveAttribute("step", "0.001");

    fireEvent.change(currency, { target: { value: "EGP" } });
    expect(dailyPrice).toHaveAttribute("step", "0.01");
  });
});
