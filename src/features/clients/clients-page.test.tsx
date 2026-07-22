import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ClientsPage } from "./clients-page";

describe("ClientsPage", () => {
  it("renders a client registry without contact details", () => {
    render(<ClientsPage clients={[{ id: "client-a", displayName: "عميل النيل", createdAt: "2026-07-22T00:00:00.000Z" }]} />);

    expect(screen.getByRole("heading", { name: "العملاء" })).toBeInTheDocument();
    expect(screen.getByText("عميل النيل")).toBeInTheDocument();
    expect(screen.getByText(/لا تظهر بيانات الاتصال في هذه المرحلة/)).toBeInTheDocument();
  });

  it("explains the empty client registry", () => {
    render(<ClientsPage clients={[]} />);
    expect(screen.getByText("لا يوجد عملاء مسجلون بعد")).toBeInTheDocument();
  });
});
