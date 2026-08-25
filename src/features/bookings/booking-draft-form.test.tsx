import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { BookingDraftForm } from "./booking-draft-form";

describe("BookingDraftForm", () => {
  it("submits major currency units with property, client, and half-open stay dates", async () => {
    const createDraft = vi.fn().mockResolvedValue({ status: "success", message: "تم إنشاء مسودة الحجز التجاري." });
    render(<BookingDraftForm createDraft={createDraft} properties={[{ id: "property-a", label: "NILE-202 — شقة النيل" }]} clients={[{ id: "client-a", label: "عميل النيل" }]} currency="EGP" />);

    fireEvent.change(screen.getByLabelText("العقار"), { target: { value: "property-a" } });
    fireEvent.change(screen.getByLabelText("العميل"), { target: { value: "client-a" } });
    fireEvent.change(screen.getByLabelText("تاريخ الوصول"), { target: { value: "2027-04-20" } });
    fireEvent.change(screen.getByLabelText("تاريخ المغادرة"), { target: { value: "2027-04-23" } });
    fireEvent.change(screen.getByLabelText("المبلغ المتفق عليه (EGP)"), { target: { value: "25000" } });
    fireEvent.click(screen.getByRole("button", { name: "إنشاء مسودة الحجز التجاري" }));

    await screen.findByText("تم إنشاء مسودة الحجز التجاري.");
    expect(createDraft).toHaveBeenCalledOnce();
    const submitted = createDraft.mock.calls[0]?.[1] as FormData;
    expect(submitted.get("amount")).toBe("25000");
    expect(submitted.get("currency")).toBe("EGP");
  });
});
