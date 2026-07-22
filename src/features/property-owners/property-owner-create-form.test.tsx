import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { PropertyOwnerCreateForm } from "./property-owner-create-form";

describe("PropertyOwnerCreateForm", () => {
  it("submits the Arabic display name to the supplied server action", async () => {
    const createOwner = vi.fn().mockResolvedValue({ status: "success", message: "تمت إضافة المالك." });
    render(<PropertyOwnerCreateForm createOwner={createOwner} />);

    fireEvent.change(screen.getByLabelText("اسم المالك"), { target: { value: "شركة النخيل" } });
    fireEvent.click(screen.getByRole("button", { name: "إضافة المالك" }));

    await screen.findByText("تمت إضافة المالك.");
    expect(createOwner).toHaveBeenCalledOnce();
  });
});
