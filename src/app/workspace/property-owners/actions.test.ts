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
vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createServerClient }));

import { archivePropertyOwnerAction, createPropertyOwnerAction, restorePropertyOwnerAction, updatePropertyOwnerAction } from "./actions";

function formData(values: Record<string, string>): FormData {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

afterEach(() => vi.clearAllMocks());

describe("property owner V1 commands", () => {
  it("sends contact details through the V1 create RPC", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(createPropertyOwnerAction({ status: "idle", message: "" }, formData({
      display_name: "شركة النخيل",
      phone: "+201000000601",
      whatsapp: "+201000000601",
      email: "owner@example.test",
      preferred_contact_method: "whatsapp",
      notes: "اتصال أساسي",
      idempotency_key: "owner-create-1",
    }))).resolves.toEqual({ status: "success", message: "تمت إضافة المالك." });
    expect(rpc).toHaveBeenCalledWith("create_property_owner_v1", expect.objectContaining({
      p_organization_id: "organization",
      p_display_name: "شركة النخيل",
      p_preferred_contact_method: "whatsapp",
      p_request_id: expect.any(String),
    }));
  });

  it("rejects an incomplete owner update before loading workspace context", async () => {
    await expect(updatePropertyOwnerAction({ status: "idle", message: "" }, formData({ property_owner_id: "owner" })))
      .resolves.toEqual({ status: "invalid", message: "أكمل بيانات المالك قبل الحفظ." });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
  });

  it("updates an owner with optimistic versioning", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(updatePropertyOwnerAction({ status: "idle", message: "" }, formData({
      property_owner_id: "owner",
      display_name: "شركة النخيل المحدثة",
      phone: "+201000000602",
      whatsapp: "+201000000602",
      email: "owner-updated@example.test",
      preferred_contact_method: "phone",
      notes: "ملاحظة",
      status: "inactive",
      expected_version: "2",
      idempotency_key: "owner-update-1",
    }))).resolves.toEqual({ status: "success", message: "تم تحديث بيانات المالك." });
    expect(rpc).toHaveBeenCalledWith("update_property_owner_v1", expect.objectContaining({
      p_property_owner_id: "owner",
      p_expected_version: 2,
      p_status: "inactive",
    }));
  });

  it("archives and restores an owner with the expected version", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(archivePropertyOwnerAction({ status: "idle", message: "" }, formData({
      property_owner_id: "owner", reason: "انتهى التعاقد", expected_version: "3", idempotency_key: "owner-archive-1",
    }))).resolves.toMatchObject({ status: "success" });
    await expect(restorePropertyOwnerAction({ status: "idle", message: "" }, formData({
      property_owner_id: "owner", expected_version: "4", idempotency_key: "owner-restore-1",
    }))).resolves.toMatchObject({ status: "success" });
    expect(rpc).toHaveBeenNthCalledWith(1, "archive_property_owner_v1", expect.objectContaining({ p_expected_version: 3 }));
    expect(rpc).toHaveBeenNthCalledWith(2, "restore_property_owner_v1", expect.objectContaining({ p_expected_version: 4 }));
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/property-owners");
  });

  it.each([
    ["update", updatePropertyOwnerAction, { property_owner_id: "owner", display_name: "شركة النخيل", status: "active", expected_version: "2", idempotency_key: "owner-update-2" }, "update_property_owner_v1"],
    ["archive", archivePropertyOwnerAction, { property_owner_id: "owner", reason: "انتهى التعاقد", expected_version: "2", idempotency_key: "owner-archive-2" }, "archive_property_owner_v1"],
    ["restore", restorePropertyOwnerAction, { property_owner_id: "owner", expected_version: "2", idempotency_key: "owner-restore-2" }, "restore_property_owner_v1"],
  ] as const)("maps expected %s command errors without exposing database details", async (_name, action, values, rpcName) => {
    for (const [code, expectedStatus] of [["42501", "denied"], ["22023", "invalid"], ["XX000", "retry"]] as const) {
      vi.clearAllMocks();
      mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
      const rpcError = { code, message: "provider detail" };
      const rpc = vi.fn().mockResolvedValue({ error: rpcError });
      mocks.createServerClient.mockResolvedValue({ rpc });

      await expect(action({ status: "idle", message: "" }, formData(values))).resolves.toMatchObject({ status: expectedStatus });
      expect(rpc).toHaveBeenCalledWith(rpcName, expect.any(Object));
      if (expectedStatus === "retry") expect(mocks.reportFailure).toHaveBeenCalled();
      else expect(mocks.reportFailure).not.toHaveBeenCalled();
    }
  });
});
