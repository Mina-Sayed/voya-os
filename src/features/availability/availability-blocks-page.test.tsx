import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AvailabilityBlocksPage } from "./availability-blocks-page";

describe("AvailabilityBlocksPage", () => {
  it("renders a maintenance block on the operational timeline", () => {
    render(<AvailabilityBlocksPage blocks={[{ id: "block-a", propertyLabel: "NILE-202 — شقة النيل", startDate: "2027-06-10", endDate: "2027-06-14", blockType: "maintenance", reason: "صيانة دورية" }]} properties={[]} />);
    expect(screen.getByRole("heading", { name: "حظر التوفر" })).toBeInTheDocument();
    expect(screen.getByText("صيانة")).toBeInTheDocument();
    expect(screen.getByText("صيانة دورية")).toBeInTheDocument();
  });
});
