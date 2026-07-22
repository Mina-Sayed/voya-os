import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { PropertyOwnersPage } from "./property-owners-page";

describe("PropertyOwnersPage", () => {
  it("renders Arabic property-owner records with their active state", () => {
    render(<PropertyOwnersPage owners={[{
      id: "owner-a",
      displayName: "شركة النخيل",
      status: "active",
      createdAt: "2026-07-22T00:00:00.000Z",
    }]} />);

    expect(screen.getByRole("heading", { name: "ملاك العقارات" })).toBeInTheDocument();
    expect(screen.getByText("شركة النخيل")).toBeInTheDocument();
    expect(screen.getByText("نشط")).toBeInTheDocument();
  });

  it("explains an empty registry without inventing records", () => {
    render(<PropertyOwnersPage owners={[]} />);

    expect(screen.getByText("لا يوجد ملاك مسجلون بعد")).toBeInTheDocument();
  });
});
