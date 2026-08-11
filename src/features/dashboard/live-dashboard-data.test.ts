import { expect, test, vi } from "vitest";
import { createOrganizationId } from "@/domain/tenancy/organization";
import { buildDashboardData, loadLiveDashboardData, type LiveDashboardInputs } from "./live-dashboard-data";

const organizationId = createOrganizationId("org-qa");

function inputs(overrides: Partial<LiveDashboardInputs> = {}): LiveDashboardInputs {
  return {
    organizationId,
    organizationName: "فُويا QA",
    operatorName: "مشغل QA",
    today: "2026-08-11",
    activePropertyCount: 2,
    bookings: [
      {
        id: "b1",
        propertyCode: "A-1",
        propertyName: "النيل",
        clientName: "عميل 1",
        status: "confirmed",
        checkIn: "2026-08-11",
        checkOut: "2026-08-13",
        hasCheckIn: false,
        hasCheckOut: false,
        createdAt: "2026-08-10T10:00:00Z",
      },
      {
        id: "b2",
        propertyCode: "A-2",
        propertyName: "المعادي",
        clientName: "عميل 2",
        status: "pending_approval",
        checkIn: "2026-08-12",
        checkOut: "2026-08-14",
        hasCheckIn: false,
        hasCheckOut: false,
        createdAt: "2026-08-10T09:00:00Z",
      },
    ],
    approvals: [
      {
        id: "a1",
        resourceType: "booking",
        resourceId: "b1",
        proposedAction: "booking.confirm",
        status: "pending",
        expiresAt: null,
        createdAt: "2026-08-11T09:00:00Z",
      },
      {
        id: "a2",
        resourceType: "booking",
        resourceId: "b2",
        proposedAction: "booking.confirm",
        status: "approved",
        expiresAt: null,
        createdAt: "2026-08-10T09:00:00Z",
      },
    ],
    ...overrides,
  };
}

test("builds live metrics and maps the work queue into the dashboard view", () => {
  const data = buildDashboardData(inputs());

  expect(data.isPreview).toBe(false);
  expect(data.dateRangeLabel).toBe("AUG 11 — AUG 17");
  expect(data.metrics.map((metric) => metric.value)).toEqual(["14٪", "1", "1"]);
  expect(data.metrics.map((metric) => metric.label)).toEqual([
    "الإشغال هذا الأسبوع",
    "وصولات اليوم",
    "قرارات معلّقة",
  ]);
  expect(data.bookings.map((booking) => booking.id)).toEqual(["b1", "b2"]);
  expect(data.bookings[0]).toMatchObject({
    organizationId,
    property: "A-1 · النيل",
    guest: "عميل 1",
    status: "confirmed",
  });
  expect(data.approvals).toHaveLength(1);
  expect(data.approvals[0]).toMatchObject({
    organizationId,
    title: "تأكيد حجز",
    detail: "A-1 · النيل · عميل 1",
    urgency: "normal",
  });
});

test("does not fabricate preview records for an empty live workspace", () => {
  const data = buildDashboardData(inputs({
    activePropertyCount: 0,
    bookings: [],
    approvals: [],
  }));

  expect(data.metrics.map((metric) => metric.value)).toEqual(["0٪", "0", "0"]);
  expect(data.bookings).toEqual([]);
  expect(data.approvals).toEqual([]);
});

test("limits occupancy to the current seven-day window and caps it at 100 percent", () => {
  const data = buildDashboardData(inputs({
    activePropertyCount: 1,
    bookings: [
      {
        id: "inside",
        propertyCode: "A-1",
        propertyName: "النيل",
        clientName: "عميل",
        status: "confirmed",
        checkIn: "2026-08-05",
        checkOut: "2026-08-20",
        hasCheckIn: false,
        hasCheckOut: false,
        createdAt: "2026-08-01T10:00:00Z",
      },
      {
        id: "outside",
        propertyCode: "A-2",
        propertyName: "المعادي",
        clientName: "عميل آخر",
        status: "confirmed",
        checkIn: "2026-08-20",
        checkOut: "2026-08-21",
        hasCheckIn: false,
        hasCheckOut: false,
        createdAt: "2026-08-01T09:00:00Z",
      },
    ],
    approvals: [],
  }));

  expect(data.metrics[0].value).toBe("100٪");
});

test("loads the dashboard through the authorized organization RPC contracts", async () => {
  const rpc = vi.fn(async (name: string) => {
    if (name === "list_booking_work_queue") return { data: [], error: null };
    if (name === "list_properties") return { data: [{ id: "p1", status: "active" }], error: null };
    return { data: [], error: null };
  });

  const data = await loadLiveDashboardData(
    { rpc } as never,
    { organizationId: organizationId, organizationName: "فُويا QA" },
    "مشغل QA",
    "2026-08-11",
  );

  expect(data.isPreview).toBe(false);
  expect(data.organizationId).toBe(organizationId);
  expect(rpc).toHaveBeenCalledWith("list_booking_work_queue", { p_organization_id: organizationId });
  expect(rpc).toHaveBeenCalledWith("list_properties", { p_organization_id: organizationId });
  expect(rpc).toHaveBeenCalledWith("list_approval_requests", { p_organization_id: organizationId, p_limit: 50 });
});
