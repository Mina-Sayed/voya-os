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

test("does not expose amendment controls to read-only viewers", () => {
  render(
    <BookingsPage
      clients={[{ id: "client-a", label: "سارة" }]}
      createDraft={vi.fn()}
      drafts={[{ id: "booking-a", propertyLabel: "NILE-01 — شقة النيل", clientLabel: "سارة", status: "confirmed", checkIn: "2026-08-04", checkOut: "2026-08-08", amountMinor: "2500000", currency: "EGP", commercialCompletionStatus: "complete", version: 1, hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-01T10:00:00Z" }]}
      canOperateStay={false}
      canApprove={false}
      canRequestAmendment={false}
      confirmBooking={vi.fn()}
      executeAmendment={vi.fn()}
      recordStay={vi.fn()}
      requestAmendment={vi.fn()}
      requestApproval={vi.fn()}
      properties={[{ id: "property-a", label: "NILE-01 — شقة النيل" }]}
      currency="EGP"
    />,
  );

  expect(screen.queryByRole("button", { name: "إرسال التعديل للاعتماد" })).not.toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "تطبيق تعديل معتمد" })).not.toBeInTheDocument();
});

test("preserves exact bigint booking amounts in the queue", () => {
  const amountMinor = "9007199254740993";
  render(
    <BookingsPage
      clients={[]}
      createDraft={vi.fn()}
      drafts={[{ id: "booking-bigint", propertyLabel: "NILE-02", clientLabel: "عميل", status: "confirmed", checkIn: "2050-01-01", checkOut: "2050-01-02", amountMinor, currency: "EGP", commercialCompletionStatus: "complete", version: 1, hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-27T00:00:00Z" }]}
      canOperateStay={false}
      canApprove={false}
      canRequestAmendment={false}
      confirmBooking={vi.fn()}
      recordStay={vi.fn()}
      requestApproval={vi.fn()}
      properties={[]}
      currency="EGP"
    />,
  );

  const exact = new Intl.NumberFormat("ar-EG").format(BigInt(amountMinor));
  expect(screen.getByText(new RegExp(`${exact}\\s+EGP`))).toBeInTheDocument();
});

test("does not offer confirmation until the server projects an executable approval", () => {
  render(
    <BookingsPage
      clients={[]}
      createDraft={vi.fn()}
      drafts={[{ id: "booking-pending", propertyLabel: "NILE-03", clientLabel: "عميل", status: "pending_approval", checkIn: "2050-01-01", checkOut: "2050-01-02", amountMinor: "1000", currency: "EGP", commercialCompletionStatus: "complete", version: 1, hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-27T00:00:00Z", hasExecutableConfirmation: false }]}
      canOperateStay={false}
      canApprove
      confirmBooking={vi.fn()}
      recordStay={vi.fn()}
      requestApproval={vi.fn()}
      properties={[]}
      currency="EGP"
    />,
  );

  expect(screen.getByText("بانتظار قرار مالك أو مدير")).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "تأكيد بعد الاعتماد" })).not.toBeInTheDocument();
});

test("offers confirmation when the server projects a valid independent approval", () => {
  render(
    <BookingsPage
      clients={[]}
      createDraft={vi.fn()}
      drafts={[{ id: "booking-approved", propertyLabel: "NILE-04", clientLabel: "عميل", status: "pending_approval", checkIn: "2050-01-01", checkOut: "2050-01-02", amountMinor: "1000", currency: "EGP", commercialCompletionStatus: "complete", version: 1, hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-27T00:00:00Z", hasExecutableConfirmation: true }]}
      canOperateStay={false}
      canApprove
      confirmBooking={vi.fn()}
      recordStay={vi.fn()}
      requestApproval={vi.fn()}
      properties={[]}
      currency="EGP"
    />,
  );

  expect(screen.getByText("تم الاعتماد وجاهز للتأكيد")).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "تأكيد بعد الاعتماد" })).toBeInTheDocument();
});

test("renders draft cancellation controls for privileged roles", () => {
  render(
    <BookingsPage
      clients={[]}
      createDraft={vi.fn()}
      drafts={[{ id: "booking-draft", propertyLabel: "NILE-05", clientLabel: "عميل", status: "draft", checkIn: "2050-01-01", checkOut: "2050-01-02", amountMinor: "1000", currency: "EGP", commercialCompletionStatus: "complete", version: 1, hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-27T00:00:00Z" }]}
      canOperateStay={false}
      canApprove={false}
      canRequestAmendment
      cancelDraft={vi.fn()}
      confirmBooking={vi.fn()}
      recordStay={vi.fn()}
      requestApproval={vi.fn()}
      requestCancellation={vi.fn()}
      properties={[]}
      currency="EGP"
    />,
  );

  expect(screen.getByRole("button", { name: "إلغاء المسودة" })).toBeInTheDocument();
});

test("does not expose cancellation controls to read-only viewers", () => {
  render(
    <BookingsPage
      clients={[]}
      createDraft={vi.fn()}
      drafts={[{ id: "booking-confirmed", propertyLabel: "NILE-06", clientLabel: "عميل", status: "confirmed", checkIn: "2050-01-01", checkOut: "2050-01-02", amountMinor: "1000", currency: "EGP", commercialCompletionStatus: "complete", version: 1, hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-27T00:00:00Z", latestApprovedCancellationId: "cancel-1" }]}
      canOperateStay={false}
      canApprove={false}
      canRequestAmendment={false}
      cancelDraft={vi.fn()}
      confirmBooking={vi.fn()}
      executeCancellation={vi.fn()}
      recordStay={vi.fn()}
      requestApproval={vi.fn()}
      requestCancellation={vi.fn()}
      properties={[]}
      currency="EGP"
    />,
  );

  expect(screen.queryByRole("button", { name: "إرسال الإلغاء للاعتماد" })).not.toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "تنفيذ الإلغاء المعتمد" })).not.toBeInTheDocument();
});

test("renders the cancellation request with an explicit unknown finance note", () => {
  render(
    <BookingsPage
      clients={[]}
      createDraft={vi.fn()}
      drafts={[{ id: "booking-confirmed", propertyLabel: "NILE-06", clientLabel: "عميل", status: "confirmed", checkIn: "2050-01-01", checkOut: "2050-01-02", amountMinor: "1000", currency: "EGP", commercialCompletionStatus: "complete", version: 1, hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-27T00:00:00Z" }]}
      canOperateStay={false}
      canApprove={false}
      canRequestAmendment
      confirmBooking={vi.fn()}
      recordStay={vi.fn()}
      requestApproval={vi.fn()}
      requestCancellation={vi.fn()}
      properties={[]}
      currency="EGP"
    />,
  );

  expect(screen.getByRole("button", { name: "إرسال الإلغاء للاعتماد" })).toBeInTheDocument();
  expect(screen.getByText(/الأثر المالي.*غير محدد/)).toBeInTheDocument();
});

test("renders cancellation execution only from the trusted executable projection", () => {
  const confirmed = { id: "booking-confirmed", propertyLabel: "NILE-06", clientLabel: "عميل", status: "confirmed", checkIn: "2050-01-01", checkOut: "2050-01-02", amountMinor: "1000", currency: "EGP", commercialCompletionStatus: "complete", version: 1, hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-27T00:00:00Z" } as const;

  const { unmount } = render(
    <BookingsPage
      clients={[]}
      createDraft={vi.fn()}
      drafts={[{ ...confirmed }]}
      canOperateStay={false}
      canApprove
      canRequestAmendment={false}
      confirmBooking={vi.fn()}
      executeCancellation={vi.fn()}
      recordStay={vi.fn()}
      requestApproval={vi.fn()}
      properties={[]}
      currency="EGP"
    />,
  );

  expect(screen.queryByRole("button", { name: "تنفيذ الإلغاء المعتمد" })).not.toBeInTheDocument();
  unmount();

  render(
    <BookingsPage
      clients={[]}
      createDraft={vi.fn()}
      drafts={[{ ...confirmed, latestApprovedCancellationId: "cancel-1" }]}
      canOperateStay={false}
      canApprove
      canRequestAmendment={false}
      confirmBooking={vi.fn()}
      executeCancellation={vi.fn()}
      recordStay={vi.fn()}
      requestApproval={vi.fn()}
      properties={[]}
      currency="EGP"
    />,
  );

  expect(screen.getByRole("button", { name: "تنفيذ الإلغاء المعتمد" })).toBeInTheDocument();
});

test("hides cancellation execution from non-approvers even with a projected approval", () => {
  render(
    <BookingsPage
      clients={[]}
      createDraft={vi.fn()}
      drafts={[{ id: "booking-confirmed", propertyLabel: "NILE-06", clientLabel: "عميل", status: "confirmed", checkIn: "2050-01-01", checkOut: "2050-01-02", amountMinor: "1000", currency: "EGP", commercialCompletionStatus: "complete", version: 1, hasCheckIn: false, hasCheckOut: false, createdAt: "2026-08-27T00:00:00Z", latestApprovedCancellationId: "cancel-1" }]}
      canOperateStay={false}
      canApprove={false}
      canRequestAmendment={false}
      confirmBooking={vi.fn()}
      executeCancellation={vi.fn()}
      recordStay={vi.fn()}
      requestApproval={vi.fn()}
      properties={[]}
      currency="EGP"
    />,
  );

  expect(screen.queryByRole("button", { name: "تنفيذ الإلغاء المعتمد" })).not.toBeInTheDocument();
});
