import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { PropertiesPage } from "./properties-page";

describe("PropertiesPage", () => {
  it("renders Arabic property records with operational identifiers", () => {
    render(<PropertiesPage properties={[{
      id: "property-a",
      code: "NILE-202",
      name: "شقة النيل",
      timezone: "Africa/Cairo",
      status: "active",
      createdAt: "2026-07-22T00:00:00.000Z",
    }]} />);

    expect(screen.getByRole("heading", { name: "العقارات" })).toBeInTheDocument();
    expect(screen.getByText("شقة النيل")).toBeInTheDocument();
    expect(screen.getByText("NILE-202")).toBeInTheDocument();
    expect(screen.getByText("نشط")).toBeInTheDocument();
  });

  it("guides the user when the organization has no properties", () => {
    render(<PropertiesPage properties={[]} />);

    expect(screen.getByText("لا توجد عقارات مسجلة بعد")).toBeInTheDocument();
  });
});
