import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ClientCreateForm } from "./client-create-form";

describe("ClientCreateForm", () => {
  it("submits the client display name to the supplied server action", async () => {
    const createClient = vi.fn().mockResolvedValue({ status: "success", message: "تمت إضافة العميل." });
    render(<ClientCreateForm createClient={createClient} />);
    fireEvent.change(screen.getByLabelText("اسم العميل"), { target: { value: "عميل النيل" } });
    fireEvent.click(screen.getByRole("button", { name: "إضافة العميل" }));
    await screen.findByText("تمت إضافة العميل.");
    expect(createClient).toHaveBeenCalledOnce();
  });
});
