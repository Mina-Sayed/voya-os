import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { BookingsPage } from "./bookings-page";

test("renders the booking work queue beside the guarded draft form", () => {
  render(
    <BookingsPage
      clients={[{ id: "client-a", label: "سارة" }]}
      createDraft={vi.fn()}
      drafts={[{ id: "draft-a", propertyLabel: "NILE-01 — شقة النيل", clientLabel: "سارة", status: "draft", checkIn: "2026-08-04", checkOut: "2026-08-08", amountMinor: "2500000", currency: "EGP", commercialCompletionStatus: "complete", version: 1, hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-01T10:00:00Z" }]}
      canOperateStay
      canApprove
      confirmBooking={vi.fn()}
      recordStay={vi.fn()}
      requestApproval={vi.fn()}
      properties={[{ id: "property-a", label: "NILE-01 — شقة النيل" }]}
      currency="EGP"
    />,
  );

  expect(screen.getByRole("heading", { name: "الإقامات والحجوزات" })).toBeInTheDocument();
  expect(screen.getByRole("heading", { name: "آخر الإقامات" })).toBeInTheDocument();
  expect(screen.getAllByText("NILE-01 — شقة النيل")).toHaveLength(2);
  expect(screen.getByText(/المبلغ المتفق عليه snapshot تجاري فقط/)).toBeInTheDocument();
});
