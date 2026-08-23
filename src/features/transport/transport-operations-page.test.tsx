import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { TransportOperationsPage } from "./transport-operations-page";

const action = vi.fn(async () => ({ status: "success" as const, message: "تم" }));
const updateStatus = vi.fn(async () => ({ status: "success" as const, message: "تم تحديث الحالة" }));

test("renders the transport workspace with honest empty states", () => {
  render(<TransportOperationsPage assignRequest={action} canManageFleet createDriver={action} createRequest={action} createVehicle={action} drivers={[]} requests={[]} updateStatus={updateStatus} vehicles={[]} />);
  expect(screen.getByRole("heading", { name: "السيارات والتحويلات" })).toBeInTheDocument();
  expect(screen.getByText("لا توجد مركبات")).toBeInTheDocument();
  expect(screen.getByText("لا يوجد سائقون")).toBeInTheDocument();
  expect(screen.getByRole("heading", { name: "لا توجد طلبات نقل بعد" })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "إضافة الطلب" })).toBeInTheDocument();
});

test("renders assigned request facts and guarded status controls", () => {
  render(<TransportOperationsPage assignRequest={action} canManageFleet createDriver={action} createRequest={action} createVehicle={action} drivers={[{ id: "driver-a", displayName: "سائق", phoneE164: null, status: "available", createdAt: "2026-08-01T10:00:00Z" }]} requests={[{ id: "request-a", requestType: "airport_transfer", status: "assigned", guestLabel: "ضيف", pickupLocation: "المطار", dropoffLocation: "العقار", pickupAt: "2026-08-01T14:00:00Z", returnAt: null, passengerCount: 2, vehicleId: "vehicle-a", vehicleName: "فان 1", driverId: "driver-a", driverName: "سائق", bookingId: null, notes: "استقبال يدوي", createdAt: "2026-08-01T10:00:00Z", updatedAt: "2026-08-01T10:00:00Z" }]} updateStatus={updateStatus} vehicles={[{ id: "vehicle-a", displayName: "فان 1", vehicleType: "van", registrationCode: "EG-1", passengerCapacity: 7, status: "available", createdAt: "2026-08-01T10:00:00Z" }]} />);
  expect(screen.getByRole("heading", { name: "ضيف" })).toBeInTheDocument();
  expect(screen.getByText("تم الإسناد")).toBeInTheDocument();
  expect(screen.getByText("فان 1 · سائق")).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "بدء التنفيذ" })).toBeInTheDocument();
});
