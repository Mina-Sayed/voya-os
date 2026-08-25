import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { BookingsPage, type BookingDraftListItem } from "./bookings-page";

const actions = {
  createDraft: vi.fn(),
  requestApproval: vi.fn(),
  confirm: vi.fn(),
  cancelDraft: vi.fn(),
  completeSnapshot: vi.fn(),
  requestAmendment: vi.fn(),
  executeAmendment: vi.fn(),
  requestCancellation: vi.fn(),
  executeCancellation: vi.fn(),
  recordStay: vi.fn(),
};

const permissions = {
  canCreate: true,
  canRequestChanges: true,
  canExecuteChanges: true,
  canCompleteSnapshot: true,
  canOperateStay: true,
};

const draft: BookingDraftListItem = {
  id: "draft-a",
  propertyId: "property-a",
  propertyLabel: "NILE-01 — شقة النيل",
  clientId: "client-a",
  clientLabel: "سارة",
  status: "draft",
  checkIn: "2026-08-04",
  checkOut: "2026-08-08",
  amountMinor: "2500000",
  currency: "EGP",
  commercialCompletionStatus: "complete",
  version: 1,
  hasCheckIn: false,
  hasCheckOut: false,
  confirmationApprovalStatus: null,
  amendmentApprovalStatus: null,
  cancellationApprovalStatus: null,
  createdAt: "2026-08-01T10:00:00Z",
};

function renderBookings(items: BookingDraftListItem[]) {
  return render(
    <BookingsPage
      actions={actions}
      clients={[{ id: "client-a", label: "سارة" }]}
      currency="EGP"
      drafts={items}
      permissions={permissions}
      properties={[{ id: "property-a", label: "NILE-01 — شقة النيل" }]}
    />,
  );
}

test("renders the booking work queue beside the guarded draft form", () => {
  renderBookings([draft]);
  expect(screen.getByRole("heading", { name: "الإقامات والحجوزات" })).toBeInTheDocument();
  expect(screen.getByRole("heading", { name: "آخر الإقامات" })).toBeInTheDocument();
  expect(screen.getAllByText("NILE-01 — شقة النيل")).toHaveLength(2);
  expect(screen.getByText(/المبلغ المتفق عليه snapshot تجاري فقط/)).toBeInTheDocument();
});

test("does not expose confirmation execution while approval is still pending", () => {
  renderBookings([{ ...draft, status: "pending_approval", confirmationApprovalStatus: "pending" }]);
  expect(screen.getByText("بانتظار قرار المالك أو المدير")).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "تنفيذ التأكيد المعتمد" })).not.toBeInTheDocument();
});

test("exposes confirmation execution only after approval", () => {
  renderBookings([{ ...draft, status: "pending_approval", confirmationApprovalStatus: "approved" }]);
  expect(screen.getByRole("button", { name: "تنفيذ التأكيد المعتمد" })).toBeInTheDocument();
});

test("viewer-style permissions keep the booking queue read only", () => {
  render(
    <BookingsPage
      actions={actions}
      clients={[{ id: "client-a", label: "سارة" }]}
      currency="EGP"
      drafts={[draft]}
      permissions={{ canCreate: false, canRequestChanges: false, canExecuteChanges: false, canCompleteSnapshot: false, canOperateStay: false }}
      properties={[{ id: "property-a", label: "NILE-01 — شقة النيل" }]}
    />,
  );
  expect(screen.queryByRole("button", { name: /إنشاء مسودة/ })).not.toBeInTheDocument();
  expect(screen.queryByText("إلغاء المسودة")).not.toBeInTheDocument();
});
