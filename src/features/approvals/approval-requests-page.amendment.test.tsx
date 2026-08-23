import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { ApprovalRequestsPage } from "./approval-requests-page";

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
  }]} />);

  expect(screen.getByRole("heading", { name: label })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "اعتماد" })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "رفض" })).toBeInTheDocument();
});
