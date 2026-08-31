import { describe, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createServerClient: vi.fn() }));

vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createServerClient }));

import { buildLiveDashboardData, loadLiveDashboardData } from "./live-dashboard-data";

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

describe("loadLiveDashboardData", () => {
  test("loads tenant-scoped read models and applies role-aware visibility", async () => {
    const rpc = vi.fn(async (name: string) => {
      const rows: Record<string, unknown[]> = {
        count_active_properties: 1,
        count_all_properties: 2,
        count_clients: 1,
        count_active_leads: 1,
        list_leads_v1_paginated: [{ id: "lead-a", name: "عميل محتمل", source: "website", status: "new", requested_check_in: null, requested_check_out: null, created_at: "2026-07-30T00:00:00Z" }],
        list_availability_blocks: [],
        count_availability_blocks: 0,
      };
      return { data: rows[name] ?? [], error: null };
    });
    mocks.createServerClient.mockResolvedValue({
      rpc,
      auth: { getUser: vi.fn().mockResolvedValue({ data: { user: { email: "operator@example.test" } }, error: null }) },
    });

    const data = await loadLiveDashboardData({ id: "membership-a", organizationId: "org-a", organizationName: "مؤسسة أ", role: "viewer", status: "active" });

    expect(data.organizationId).toBe("org-a");
    expect(data.operatorName).toBe("operator");
    expect(rpc).toHaveBeenCalledWith("count_active_properties", { p_organization_id: "org-a" });
    expect(rpc).toHaveBeenCalledWith("count_all_properties", { p_organization_id: "org-a" });
    expect(rpc).toHaveBeenCalledWith("count_clients", { p_organization_id: "org-a" });
    expect(rpc).toHaveBeenCalledWith("count_active_leads", { p_organization_id: "org-a" });
    expect(rpc).toHaveBeenCalledWith("list_leads_v1_paginated", { p_organization_id: "org-a", p_limit: 5, p_offset: 0 });
    expect(rpc).not.toHaveBeenCalledWith("list_approval_requests", expect.anything());
  });

  test("raises a safe workspace operation error when a read model fails", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: null, error: { code: "XX000", message: "provider detail" } });
    mocks.createServerClient.mockResolvedValue({
      rpc,
      auth: { getUser: vi.fn().mockResolvedValue({ data: { user: null }, error: null }) },
    });

    await expect(loadLiveDashboardData({ id: "membership-a", organizationId: "org-a", organizationName: "مؤسسة أ", role: "viewer", status: "active" }))
      .rejects.toThrow("Workspace dependency is unavailable.");
  });
});
