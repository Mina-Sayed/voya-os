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

describe("AvailabilityBlocksPage edit controls", () => {
  const block = { id: "block-a", propertyLabel: "NILE-202 — شقة النيل", startDate: "2027-06-10", endDate: "2027-06-14", blockType: "maintenance" as const, reason: null };

  it("shows edit and delete controls only when both actions are provided", async () => {
    const action = async () => ({ status: "idle" as const, message: "" });
    const { rerender } = render(<AvailabilityBlocksPage blocks={[block]} properties={[]} />);
    expect(screen.queryByText("تعديل أو حذف")).not.toBeInTheDocument();
    rerender(<AvailabilityBlocksPage blocks={[block]} deleteBlock={action} properties={[]} updateBlock={action} />);
    expect(screen.getByText("تعديل أو حذف")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "حفظ التعديل" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "حذف الحظر" })).toBeInTheDocument();
    expect(screen.getByDisplayValue("2027-06-10")).toBeInTheDocument();
  });
});
