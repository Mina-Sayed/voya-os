import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { PropertyCreateForm } from "./property-create-form";

describe("PropertyCreateForm", () => {
  it("submits the property identity fields to the supplied server action", async () => {
    const createProperty = vi.fn().mockResolvedValue({ status: "success", message: "تمت إضافة العقار." });
    render(<PropertyCreateForm createProperty={createProperty} />);

    fireEvent.change(screen.getByLabelText("رمز العقار"), { target: { value: "NILE-202" } });
    fireEvent.change(screen.getByLabelText("اسم العقار"), { target: { value: "شقة النيل" } });
    fireEvent.change(screen.getByLabelText("المنطقة الزمنية"), { target: { value: "Africa/Cairo" } });
    fireEvent.click(screen.getByRole("button", { name: "إضافة العقار" }));

    await screen.findByText("تمت إضافة العقار.");
    expect(createProperty).toHaveBeenCalledOnce();
  });
});
