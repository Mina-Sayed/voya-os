import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { VoyaStayMediaCleanupForm, VoyaStayPublicationForm } from "./voya-stay-publication-form";

describe("VOYA Stay publication form", () => {
  it("requires staff to explicitly select source photos and submit approved public copy", () => {
    render(<VoyaStayPublicationForm
      property={{
        id: "aaaaaaaa-0000-0000-0000-000000000001",
        name: "الشقة الداخلية",
        city: "القاهرة",
        district: "المعادي",
        bedrooms: 2,
        maxGuests: 4,
        marketingDescription: "وصف مراجَع",
        amenities: ["wifi"],
        imageIds: ["aaaaaaaa-0000-0000-0000-000000000811", "aaaaaaaa-0000-0000-0000-000000000812"],
      }}
      publish={vi.fn()}
      unpublish={vi.fn()}
    />);

    expect(screen.getByRole("textbox", { name: "العنوان العام" })).toHaveValue("الشقة الداخلية");
    const publicSlug = (screen.getByRole("textbox", { name: "الرابط العام" }) as HTMLInputElement).value;
    expect(publicSlug).toMatch(/^stay-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u);
    expect(publicSlug).not.toBe("stay-aaaaaaaa");
    expect(screen.getByRole("textbox", { name: "المنطقة المعروضة" })).toHaveValue("المعادي");
    expect(screen.getByRole("checkbox", { name: "استخدام الصورة 1" })).not.toBeChecked();
    expect(screen.getByRole("checkbox", { name: "استخدام الصورة 2" })).not.toBeChecked();
    fireEvent.click(screen.getByRole("checkbox", { name: "استخدام الصورة 1" }));
    expect(screen.getByRole("checkbox", { name: "استخدام الصورة 1" })).toBeChecked();
    expect(screen.getByRole("button", { name: "نشر على VOYA Stay" })).toBeEnabled();
    expect(screen.getByText(/لن تنتقل الصور الخاصة/u)).toBeInTheDocument();
  });

  it("provides a separate unpublish command for an already published listing", () => {
    render(<VoyaStayPublicationForm
      listing={{ id: "aaaaaaaa-0000-0000-0000-000000000821", slug: "stay-a101", title: "إقامة عامة", status: "published", version: 3, description: "وصف عام", areaLabel: "المعادي", bedrooms: 2, maxGuests: 4, amenities: ["wifi"], pendingMediaCleanup: false }}
      property={{ id: "aaaaaaaa-0000-0000-0000-000000000001", name: "الشقة الداخلية", imageIds: ["aaaaaaaa-0000-0000-0000-000000000811"] }}
      publish={vi.fn()}
      unpublish={vi.fn()}
    />);

    expect(screen.getByText(/منشور على VOYA Stay/u)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "إخفاء من VOYA Stay" })).toBeEnabled();
  });

  it("keeps failed derivative cleanup actionable after a property is unpublished", () => {
    render(<VoyaStayMediaCleanupForm
      listing={{ id: "aaaaaaaa-0000-0000-0000-000000000821", slug: "stay-a101", title: "إقامة عامة", status: "unpublished", version: 4, description: "وصف عام", areaLabel: "المعادي", bedrooms: 2, maxGuests: 4, amenities: ["wifi"], pendingMediaCleanup: true }}
      cleanup={vi.fn()}
    />);

    expect(screen.getByText("الإقامة مخفية. ما زالت هناك صورة عامة تنتظر التنظيف.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "إعادة محاولة حذف الصور العامة" })).toBeEnabled();
  });
});
