import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ApprovalRequestsPage, type ApprovalRequestItem } from "./approval-requests-page";

const baseRequest: ApprovalRequestItem = {
  id: "approval-a",
  resourceId: "booking-a",
  resourceType: "booking",
  proposedAction: "booking.confirm",
  status: "pending",
  expiresAt: null,
  createdAt: "2026-07-22T00:00:00.000Z",
  requesterName: "Mina",
  currentPropertyCode: null,
  currentPropertyName: null,
  currentClientName: null,
  currentCheckIn: null,
  currentCheckOut: null,
  currentAmountMinor: null,
  currentCurrency: null,
  proposedPropertyCode: "NILE-01",
  proposedPropertyName: "شقة النيل",
  proposedClientName: "سارة",
  proposedCheckIn: "2026-08-04",
  proposedCheckOut: "2026-08-08",
  proposedAmountMinor: "2500000",
  proposedCurrency: "EGP",
  reason: null,
};

describe("ApprovalRequestsPage", () => {
  it("shows the booking snapshot required to make a confirmation decision", () => {
    render(<ApprovalRequestsPage canDecide={false} decide={vi.fn()} requests={[baseRequest]} />);
    expect(screen.getByRole("heading", { name: "طلبات الموافقة" })).toBeInTheDocument();
    expect(screen.getByText("تأكيد حجز")).toBeInTheDocument();
    expect(screen.getByText("قيد المراجعة")).toBeInTheDocument();
    expect(screen.getByText("مقدم الطلب: Mina")).toBeInTheDocument();
    expect(screen.getByText(/NILE-01/)).toBeInTheDocument();
    expect(screen.getByText(/سارة/)).toBeInTheDocument();
    expect(screen.getByText(/EGP/)).toBeInTheDocument();
  });

  it("shows current and proposed snapshots for booking amendments", () => {
    render(
      <ApprovalRequestsPage
        canDecide={false}
        decide={vi.fn()}
        requests={[{
          ...baseRequest,
          proposedAction: "booking.amend",
          currentPropertyCode: "NILE-01",
          currentPropertyName: "شقة النيل",
          currentClientName: "سارة",
          currentCheckIn: "2026-08-04",
          currentCheckOut: "2026-08-08",
          currentAmountMinor: "2500000",
          currentCurrency: "EGP",
          proposedCheckOut: "2026-08-10",
          proposedAmountMinor: "3000000",
          reason: "تمديد الإقامة",
        }]}
      />,
    );
    expect(screen.getByText("تعديل حجز")).toBeInTheDocument();
    expect(screen.getByText("قبل")).toBeInTheDocument();
    expect(screen.getByText("المقترح")).toBeInTheDocument();
    expect(screen.getByText(/تمديد الإقامة/)).toBeInTheDocument();
  });

  it("shows maker-checker decision controls only to eligible reviewers", () => {
    const decide = vi.fn();
    render(<ApprovalRequestsPage canDecide decide={decide} requests={[baseRequest]} />);
    expect(screen.getByRole("button", { name: "اعتماد" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "رفض" })).toBeInTheDocument();
    expect(screen.getAllByLabelText("سبب القرار")).toHaveLength(2);
  });

  it("explains an empty approval queue", () => {
    render(<ApprovalRequestsPage canDecide={false} decide={vi.fn()} requests={[]} />);
    expect(screen.getByText("لا توجد طلبات موافقة مرئية")).toBeInTheDocument();
  });
});
