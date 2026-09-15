import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createServerClient: vi.fn(),
  loadMembership: vi.fn(),
  reportFailure: vi.fn(),
  revalidatePath: vi.fn(),
}));

vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: mocks.createServerClient,
  createServiceRoleSupabaseClient: vi.fn(),
}));

import { updatePropertyAction } from "./actions";

function legacyUpdateForm(): FormData {
  const data = new FormData();
  const values = {
    property_id: "property-legacy",
    code: "LEGACY-1",
    name: "عقار قديم بعد المراجعة",
    timezone: "America/Toronto",
    bedrooms: "2",
    max_guests: "4",
    daily_price: "100.125",
    monthly_price: "35000.125",
    currency: "XYZ",
    status: "active",
    expected_version: "7",
    idempotency_key: "legacy-update-1",
  };
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

afterEach(() => vi.clearAllMocks());

describe("legacy property recovery updates", () => {
  it("forwards a legacy currency/timezone snapshot so PostgreSQL can allow unchanged legacy values and reject actual contract changes", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(updatePropertyAction({ status: "idle", message: "" }, legacyUpdateForm()))
      .resolves.toEqual({ status: "success", message: "تم تحديث بيانات العقار." });

    expect(rpc).toHaveBeenCalledWith("update_property_v1", expect.objectContaining({
      p_organization_id: "organization",
      p_property_id: "property-legacy",
      p_timezone: "America/Toronto",
      p_currency: "XYZ",
      p_daily_price: 100.125,
      p_monthly_price: 35000.125,
      p_expected_version: 7,
    }));
  });
});
