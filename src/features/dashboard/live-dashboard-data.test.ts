import { expect, test } from "vitest";
import { buildLiveDashboardData } from "./live-dashboard-data";

test("builds tenant-scoped dashboard data from live read models", () => {
  const data = buildLiveDashboardData({
    organizationId: "org-live",
    organizationName: "فُويا للاختبار",
    operatorName: "مينا",
    properties: [
      { id: "property-a", code: "NILE-01", name: "شقة النيل", timezone: "Africa/Cairo", status: "active", created_at: "2026-07-30T00:00:00Z" },
      { id: "property-b", code: "MAADI-02", name: "دار المعادي", timezone: "Africa/Cairo", status: "inactive", created_at: "2026-07-30T00:00:00Z" },
    ],
    clients: [{ id: "client-a", display_name: "سارة", created_at: "2026-07-30T00:00:00Z" }],
    leads: [{ id: "lead-a", title: "طلب إقامة صيفية", source: "website", status: "new", requested_check_in: "2026-08-04", requested_check_out: "2026-08-08", created_at: "2026-07-30T00:00:00Z" }],
    approvals: [{ id: "approval-a", resource_type: "booking", resource_id: "booking-a", proposed_action: "booking.confirm", status: "pending", expires_at: null, created_at: "2026-07-30T00:00:00Z" }],
    availabilityBlocks: [{ id: "block-a", property_id: "property-a", start_date: "2026-08-10", end_date: "2026-08-12", block_type: "maintenance", reason: "صيانة" }],
  });

  expect(data.isPreview).toBe(false);
  expect(data.metrics.map((metric) => metric.value)).toEqual(["1", "1", "1", "1"]);
  expect(data.recentLeads[0]).toMatchObject({ id: "lead-a", title: "طلب إقامة صيفية" });
  expect(data.approvals[0]).toMatchObject({ id: "approval-a", urgency: "attention" });
});
