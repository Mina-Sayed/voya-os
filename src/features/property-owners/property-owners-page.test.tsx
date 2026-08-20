import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { PropertyOwnersPage } from "./property-owners-page";

describe("PropertyOwnersPage", () => {
  it("renders Arabic property-owner records with their active state", () => {
    render(<PropertyOwnersPage owners={[{
      id: "owner-a",
      displayName: "شركة النخيل",
      status: "active",
      phone: "+201000000601",
      whatsapp: "+201000000601",
      email: "owner@example.test",
      preferredContactMethod: "whatsapp",
      notes: "اتصال أساسي",
      version: 1,
      createdAt: "2026-07-22T00:00:00.000Z",
      archivedAt: null,
    }]} />);

    expect(screen.getByRole("heading", { name: "ملاك العقارات" })).toBeInTheDocument();
    expect(screen.getByText("شركة النخيل")).toBeInTheDocument();
    expect(screen.getByText("نشط")).toBeInTheDocument();
    expect(screen.getByText("owner@example.test")).toBeInTheDocument();
  });

  it("explains an empty registry without inventing records", () => {
    render(<PropertyOwnersPage owners={[]} />);

    expect(screen.getByText("لا يوجد ملاك مسجلون بعد")).toBeInTheDocument();
  });
});
