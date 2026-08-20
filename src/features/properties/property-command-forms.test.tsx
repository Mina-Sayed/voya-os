import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { PropertyArchiveForm } from "./property-archive-form";
import { PropertyEditForm } from "./property-edit-form";
import { PropertyImageUploadForm } from "./property-image-upload-form";
import { PropertyOwnerAssignmentForm } from "./property-owner-assignment-form";

const property = {
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
  status: "active" as const,
  version: 3,
  createdAt: "2026-07-22T00:00:00.000Z",
  updatedAt: "2026-07-22T00:00:00.000Z",
  archivedAt: null,
  currentPropertyOwnerName: null,
  imageCount: 0,
  imageIds: [],
};

describe("property command forms", () => {
  it("renders guarded edit, assignment, image, and archive controls", () => {
    const action = vi.fn().mockResolvedValue({ status: "success", message: "تم الحفظ." });
    render(
      <div>
        <PropertyEditForm property={property} updateProperty={action} />
        <PropertyOwnerAssignmentForm propertyId="property-a" owners={[{ id: "owner-a", displayName: "شركة النخيل" }]} assignOwner={action} />
        <PropertyImageUploadForm propertyId="property-a" uploadImage={action} />
        <PropertyArchiveForm propertyId="property-a" version={3} archiveProperty={action} />
      </div>,
    );

    expect(screen.getByDisplayValue("NILE-202")).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "شركة النخيل" })).toBeInTheDocument();
    expect(screen.getByText("JPEG / PNG / WebP · 10MB")).toBeInTheDocument();
    expect(screen.getByText("سبب الأرشفة")).toBeInTheDocument();
    expect(screen.getAllByDisplayValue("property-a")).toHaveLength(4);
  });

  it("wires a valid archive submission to the supplied server action", async () => {
    const archiveProperty = vi.fn().mockResolvedValue({ status: "success", message: "تمت أرشفة العقار." });
    render(<PropertyArchiveForm propertyId="property-a" version={3} archiveProperty={archiveProperty} />);
    fireEvent.change(screen.getByRole("textbox", { name: "سبب الأرشفة" }), { target: { value: "لم يعد ضمن المخزون" } });
    fireEvent.click(screen.getByRole("button", { name: "تأكيد الأرشفة" }));

    await screen.findByText("تمت أرشفة العقار.");
    expect(archiveProperty).toHaveBeenCalledOnce();
  });
});
