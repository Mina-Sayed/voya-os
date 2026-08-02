import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { BookingsPage } from "./bookings-page";

test("renders the booking work queue beside the guarded draft form", () => {
  render(
    <BookingsPage
      clients={[{ id: "client-a", label: "سارة" }]}
      createDraft={vi.fn()}
      drafts={[{ id: "draft-a", propertyLabel: "NILE-01 — شقة النيل", clientLabel: "سارة", status: "draft", checkIn: "2026-08-04", checkOut: "2026-08-08", hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-01T10:00:00Z" }]}
      canOperateStay
      confirmBooking={vi.fn()}
      recordStay={vi.fn()}
      requestApproval={vi.fn()}
      properties={[{ id: "property-a", label: "NILE-01 — شقة النيل" }]}
    />,
  );

  expect(screen.getByRole("heading", { name: "الإقامات والحجوزات" })).toBeInTheDocument();
  expect(screen.getByRole("heading", { name: "آخر الإقامات" })).toBeInTheDocument();
  expect(screen.getAllByText("NILE-01 — شقة النيل")).toHaveLength(2);
  expect(screen.getByText(/لا توجد هنا أسعار أو دفعات/)).toBeInTheDocument();
});
