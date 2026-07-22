import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { LeadsPage } from "./leads-page";

describe("LeadsPage", () => {
  it("renders an Arabic operational lead registry without contact details", () => {
    render(<LeadsPage leads={[{ id: "lead-a", title: "إقامة صيفية", source: "website", status: "new", requestedCheckIn: "2027-06-01", requestedCheckOut: "2027-06-05", createdAt: "2026-07-22T00:00:00.000Z" }]} />);
    expect(screen.getByRole("heading", { name: "العملاء المحتملون" })).toBeInTheDocument();
    expect(screen.getByText("إقامة صيفية")).toBeInTheDocument();
    expect(screen.getByText(/لا تجمع هذه المرحلة بيانات اتصال أو أسعار/)).toBeInTheDocument();
  });
});
