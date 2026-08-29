import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { PropertiesPage } from "./properties-page";

describe("PropertiesPage", () => {
  it("renders Arabic property records with operational identifiers", () => {
    render(<PropertiesPage properties={[{
      id: "property-a",
      code: "NILE-202",
      name: "شقة النيل",
      timezone: "Africa/Cairo",
      address: "12 شارع النيل",
      city: "القاهرة",
      unitLabel: "A-202",
      bedrooms: 2,
      maxGuests: 4,
      operationalNotes: "دخول ذاتي",
      bathrooms: 2,
      areaSqm: 90.5,
      district: "مدينة نصر",
      furnished: true,
      monthlyPrice: 35000,
      currency: "EGP",
      status: "active",
      version: 1,
      createdAt: "2026-07-22T00:00:00.000Z",
      updatedAt: "2026-07-22T00:00:00.000Z",
      archivedAt: null,
      currentPropertyOwnerName: "شركة النخيل",
      imageCount: 3,
      imageIds: ["image-a"],
    }]} />);

    expect(screen.getByRole("heading", { name: "العقارات" })).toBeInTheDocument();
    expect(screen.getByText("شقة النيل")).toBeInTheDocument();
    expect(screen.getByText("NILE-202")).toBeInTheDocument();
    expect(screen.getByText("نشط")).toBeInTheDocument();
    expect(screen.getByText(/شركة النخيل/u)).toBeInTheDocument();
    expect(screen.getByText(/3 صور خاصة/u)).toBeInTheDocument();
    expect(screen.getByText(/مدينة نصر · 90.5 م²/u)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "فتح الصورة 1" })).toHaveAttribute("href", "/api/workspace/properties/property-a/images/image-a");
  });

  it("exposes guarded edit and archive commands only when supplied", () => {
    const action = vi.fn();
    render(<PropertiesPage
      canManage
      properties={[{
        id: "property-a",
        code: "NILE-202",
        name: "شقة النيل",
        timezone: "Africa/Cairo",
        address: null,
        city: null,
        unitLabel: null,
        bedrooms: null,
        maxGuests: null,
        operationalNotes: null,
        status: "active",
        version: 1,
        createdAt: "2026-07-22T00:00:00.000Z",
        updatedAt: "2026-07-22T00:00:00.000Z",
        archivedAt: null,
        currentPropertyOwnerName: null,
        imageCount: 0,
        imageIds: [],
      }]}
      updateProperty={action}
      archiveProperty={action}
    />);

    expect(screen.getByText("تعديل بيانات العقار")).toBeInTheDocument();
    expect(screen.getByText("أرشفة العقار")).toBeInTheDocument();
  });

  it("guides the user when the organization has no properties", () => {
    render(<PropertiesPage properties={[]} />);

    expect(screen.getByText("لا توجد عقارات مسجلة بعد")).toBeInTheDocument();
  });
});
