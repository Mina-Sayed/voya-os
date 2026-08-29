import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ApprovalRequestsPage } from "./approval-requests-page";

describe("ApprovalRequestsPage", () => {
  it("renders a pending booking approval without exposing its snapshot", () => {
    render(<ApprovalRequestsPage canDecide={false} decide={vi.fn()} requests={[{ id: "approval-a", resourceId: "booking-a", resourceType: "booking", proposedAction: "booking.confirm", status: "pending", expiresAt: null, createdAt: "2026-07-22T00:00:00.000Z" }]} />);
    expect(screen.getByRole("heading", { name: "طلبات الموافقة" })).toBeInTheDocument();
    expect(screen.getByText("تأكيد حجز")).toBeInTheDocument();
    expect(screen.getByText("قيد المراجعة")).toBeInTheDocument();
  });

  it("shows maker-checker decision controls only to eligible reviewers", () => {
    const decide = vi.fn();
    render(<ApprovalRequestsPage canDecide decide={decide} requests={[{ id: "approval-a", resourceId: "booking-a", resourceType: "booking", proposedAction: "booking.confirm", status: "pending", expiresAt: null, createdAt: "2026-07-22T00:00:00.000Z" }]} />);
    expect(screen.getByRole("button", { name: "اعتماد" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "رفض" })).toBeInTheDocument();
    expect(screen.getAllByLabelText("سبب القرار")).toHaveLength(2);
    expect(screen.getAllByRole("textbox")[0]).toHaveAttribute("placeholder", "تمت مراجعة الطلب والتأثير التشغيلي");
  });

  it("explains an empty approval queue", () => {
    render(<ApprovalRequestsPage canDecide={false} decide={vi.fn()} requests={[]} />);
    expect(screen.getByText("لا توجد طلبات موافقة مرئية")).toBeInTheDocument();
  });
});
