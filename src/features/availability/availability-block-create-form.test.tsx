import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { AvailabilityBlockCreateForm } from "./availability-block-create-form";

describe("AvailabilityBlockCreateForm", () => {
  it("submits a maintenance block to the supplied server action", async () => {
    const createBlock = vi.fn().mockResolvedValue({ status: "success", message: "تمت إضافة حظر التوفر." });
    render(<AvailabilityBlockCreateForm createBlock={createBlock} properties={[{ id: "property-a", label: "NILE-202 — شقة النيل" }]} />);
    fireEvent.change(screen.getByLabelText("العقار"), { target: { value: "property-a" } });
    fireEvent.change(screen.getByLabelText("بداية الحظر"), { target: { value: "2027-06-10" } });
    fireEvent.change(screen.getByLabelText("نهاية الحظر"), { target: { value: "2027-06-14" } });
    fireEvent.change(screen.getByLabelText("نوع الحظر"), { target: { value: "maintenance" } });
    fireEvent.click(screen.getByRole("button", { name: "إضافة الحظر" }));
    await screen.findByText("تمت إضافة حظر التوفر.");
    expect(createBlock).toHaveBeenCalledOnce();
  });
});
