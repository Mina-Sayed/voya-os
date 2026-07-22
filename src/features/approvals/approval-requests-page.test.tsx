import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ApprovalRequestsPage } from "./approval-requests-page";

describe("ApprovalRequestsPage", () => {
  it("renders a pending booking approval without exposing its snapshot", () => {
    render(<ApprovalRequestsPage requests={[{ id: "approval-a", resourceType: "booking", proposedAction: "booking.confirm", status: "pending", expiresAt: null, createdAt: "2026-07-22T00:00:00.000Z" }]} />);
    expect(screen.getByRole("heading", { name: "طلبات الموافقة" })).toBeInTheDocument();
    expect(screen.getByText("تأكيد حجز")).toBeInTheDocument();
    expect(screen.getByText("قيد المراجعة")).toBeInTheDocument();
  });

  it("explains an empty approval queue", () => {
    render(<ApprovalRequestsPage requests={[]} />);
    expect(screen.getByText("لا توجد طلبات موافقة مرئية")).toBeInTheDocument();
  });
});
