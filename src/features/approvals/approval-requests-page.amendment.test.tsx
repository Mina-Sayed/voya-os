import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { ApprovalRequestsPage, type ApprovalRequestItem } from "./approval-requests-page";

const decide = vi.fn(async () => ({ status: "success" as const, message: "تم" }));

test.each([
  ["booking.amend", "تعديل حجز"],
  ["booking.cancel", "إلغاء حجز"],
] as const)("renders maker-checker decision controls for %s", (proposedAction, label) => {
  render(<ApprovalRequestsPage canDecide decide={decide} requests={[{
    id: `approval-${proposedAction}`,
    resourceType: "booking",
    resourceId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    proposedAction,
    status: "pending",
    expiresAt: "2099-01-01T00:00:00Z",
    createdAt: "2026-08-24T00:00:00Z",
    proposalSummary: {
      checkIn: "2050-01-10",
      checkOut: "2050-01-14",
      amountMinor: "3000000",
      currency: "EGP",
      reason: "تمديد الإقامة",
      propertyId: "aaaaaaaa-0000-0000-0000-000000000001",
      clientId: "aaaaaaaa-0000-0000-0000-000000000002",
      propertyLabel: "NILE-01 — شقة النيل",
      clientLabel: "عميل الشركات",
    } as ApprovalRequestItem["proposalSummary"],
    requesterDisplayName: "سارة",
  }]} />);

  expect(screen.getByRole("heading", { name: label })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "اعتماد" })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "رفض" })).toBeInTheDocument();
  expect(screen.getByText("تمديد الإقامة")).toBeInTheDocument();
  expect(screen.getByText("سارة")).toBeInTheDocument();
  if (proposedAction === "booking.amend") {
    expect(screen.getByText("NILE-01 — شقة النيل")).toBeInTheDocument();
    expect(screen.getByText("عميل الشركات")).toBeInTheDocument();
  }
});

test("allows a historical cancellation decision without inventing commercial data", () => {
  render(<ApprovalRequestsPage canDecide decide={decide} requests={[{
    id: "approval-historical-cancel",
    resourceType: "booking",
    resourceId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    proposedAction: "booking.cancel",
    status: "pending",
    expiresAt: "2099-01-01T00:00:00Z",
    createdAt: "2026-08-24T00:00:00Z",
    proposalSummary: {
      checkIn: "2026-07-01",
      checkOut: "2026-07-05",
      amountMinor: null,
      currency: null,
      reason: "إلغاء حجز تاريخي",
      propertyId: "aaaaaaaa-0000-0000-0000-000000000001",
      clientId: null,
      propertyLabel: "NILE-01 — شقة النيل",
      clientLabel: "عميل غير مرتبط",
    },
    requesterDisplayName: "سارة",
  }]} />);

  expect(screen.getByRole("button", { name: "اعتماد" })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "رفض" })).toBeInTheDocument();
  expect(screen.getByText("عميل غير مرتبط")).toBeInTheDocument();
  expect(screen.queryByText(/المبلغ المقترح/)).not.toBeInTheDocument();
});

test("does not enable amend or cancel decisions without a proposal summary", () => {
  render(<ApprovalRequestsPage canDecide decide={decide} requests={[{
    id: "approval-booking-amend",
    resourceType: "booking",
    resourceId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    proposedAction: "booking.amend",
    status: "pending",
    expiresAt: "2099-01-01T00:00:00Z",
    createdAt: "2026-08-24T00:00:00Z",
    proposalSummary: null,
    requesterDisplayName: null,
  }]} />);

  expect(screen.queryByRole("button", { name: "اعتماد" })).not.toBeInTheDocument();
  expect(screen.getByText("لا يمكن اعتماد التغيير قبل عرض تفاصيله بأمان.")).toBeInTheDocument();
});

test("renders bigint commercial amounts without JavaScript Number precision loss", () => {
  const amountMinor = "9007199254740993";
  render(<ApprovalRequestsPage canDecide decide={decide} requests={[{
    id: "approval-bigint-amendment",
    resourceType: "booking",
    resourceId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    proposedAction: "booking.amend",
    status: "pending",
    expiresAt: "2099-01-01T00:00:00Z",
    createdAt: "2026-08-27T00:00:00Z",
    proposalSummary: {
      checkIn: "2050-01-10",
      checkOut: "2050-01-14",
      amountMinor,
      currency: "EGP",
      reason: "اختبار دقة المبلغ",
      propertyId: "aaaaaaaa-0000-0000-0000-000000000001",
      clientId: "aaaaaaaa-0000-0000-0000-000000000002",
      propertyLabel: "NILE-01 — شقة النيل",
      clientLabel: "عميل الشركات",
    },
    requesterDisplayName: "سارة",
  }]} />);
  const exact = new Intl.NumberFormat("ar-EG").format(BigInt("90071992547409"));
  const fraction = new Intl.NumberFormat("ar-EG").format(93);
  expect(screen.getByText(new RegExp(`${exact}٫${fraction}\\s+EGP`))).toBeInTheDocument();
});
