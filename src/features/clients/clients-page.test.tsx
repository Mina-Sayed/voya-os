import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ClientsPage } from "./clients-page";

describe("ClientsPage", () => {
  it("renders a CRM client registry", () => {
    render(<ClientsPage clients={[{ id: "client-a", displayName: "عميل النيل", createdAt: "2026-07-22T00:00:00.000Z" }]} />);

    expect(screen.getByRole("heading", { name: "العملاء" })).toBeInTheDocument();
    expect(screen.getByText("عميل النيل")).toBeInTheDocument();
    expect(screen.getByText(/بيانات الاتصال والملاحظات/)).toBeInTheDocument();
  });

  it("shows permanent delete confirmation only when owner action is supplied", () => {
    const client = { id: "client-a", displayName: "عميل النيل", version: 4,
      createdAt: "2026-07-22T00:00:00.000Z" };
    const action = async () => ({ status: "idle" as const, message: "" });
    const { rerender, container } = render(<ClientsPage clients={[client]} />);
    expect(screen.queryByText("حذف العميل نهائيًا (للمالك فقط)")).not.toBeInTheDocument();
    rerender(<ClientsPage clients={[client]} deleteClient={action} />);
    expect(screen.getByText("حذف العميل نهائيًا (للمالك فقط)")).toBeInTheDocument();
    const form = container.querySelector('input[name="confirm_name"]')?.closest("form");
    expect(form).not.toBeNull();
    expect(new FormData(form!).get("client_id")).toBe("client-a");
    expect(new FormData(form!).get("expected_version")).toBe("4");
    expect(form?.querySelector('input[name="confirm_name"]')).toBeRequired();
  });

  it("explains the empty client registry", () => {
    render(<ClientsPage clients={[]} />);
    expect(screen.getByText("لا يوجد عملاء مسجلون بعد")).toBeInTheDocument();
  });
});
