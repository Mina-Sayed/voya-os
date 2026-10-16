import { afterEach, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createServerClient: vi.fn(),
  loadMembership: vi.fn(),
  revalidatePath: vi.fn(),
  reportFailure: vi.fn(),
}));

vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createServerClient }));

import { deleteAvailabilityBlockAction, updateAvailabilityBlockAction } from "./actions";

const blockId = "aaaaaaaa-0000-0000-0000-000000000001";
const idle = { status: "idle" as const, message: "" };
function form(values: Record<string, string>) {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}
const validEdit = { block_id: blockId, start_date: "2027-06-10", end_date: "2027-06-14", block_type: "maintenance", reason: " صيانة " };

afterEach(() => vi.clearAllMocks());

test("rejects invalid edits before any tenant lookup", async () => {
  await expect(updateAvailabilityBlockAction(idle, form({ ...validEdit, block_id: "not-a-uuid" }))).resolves.toMatchObject({ status: "invalid" });
  await expect(updateAvailabilityBlockAction(idle, form({ ...validEdit, end_date: "2027-06-10" }))).resolves.toMatchObject({ status: "invalid" });
  await expect(updateAvailabilityBlockAction(idle, form({ ...validEdit, block_type: "party" }))).resolves.toMatchObject({ status: "invalid" });
  expect(mocks.loadMembership).not.toHaveBeenCalled();
});

test("updates a block through the tenant-scoped versioned RPC", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "org-a", role: "operations" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });

  await expect(updateAvailabilityBlockAction(idle, form(validEdit))).resolves.toEqual({ status: "success", message: "تم تعديل الحظر." });
  expect(rpc).toHaveBeenCalledWith("update_availability_block_v1", expect.objectContaining({
    p_organization_id: "org-a", p_block_id: blockId, p_start_date: "2027-06-10", p_end_date: "2027-06-14", p_block_type: "maintenance", p_reason: "صيانة", p_request_id: expect.any(String),
  }));
  expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/availability");
});

test("maps occupancy conflicts, denials and unknown failures", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "org-a", role: "operations" });
  const rpc = vi.fn();
  mocks.createServerClient.mockResolvedValue({ rpc });
  rpc.mockResolvedValueOnce({ error: { code: "23P01" } });
  await expect(updateAvailabilityBlockAction(idle, form(validEdit))).resolves.toMatchObject({ status: "invalid" });
  rpc.mockResolvedValueOnce({ error: { code: "42501" } });
  await expect(updateAvailabilityBlockAction(idle, form(validEdit))).resolves.toMatchObject({ status: "denied" });
  const failure = { code: "XX000" };
  rpc.mockResolvedValueOnce({ error: failure });
  await expect(updateAvailabilityBlockAction(idle, form(validEdit))).resolves.toMatchObject({ status: "retry" });
  expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.availability.update", failure, expect.any(String));
  expect(mocks.revalidatePath).not.toHaveBeenCalled();
});

test("deletes a block and denies callers without a workspace", async () => {
  await expect(deleteAvailabilityBlockAction(idle, form({ block_id: "" }))).resolves.toMatchObject({ status: "invalid" });
  mocks.loadMembership.mockResolvedValueOnce(null);
  await expect(deleteAvailabilityBlockAction(idle, form({ block_id: blockId }))).resolves.toMatchObject({ status: "denied" });

  mocks.loadMembership.mockResolvedValue({ organizationId: "org-a", role: "manager" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });
  await expect(deleteAvailabilityBlockAction(idle, form({ block_id: blockId }))).resolves.toEqual({ status: "success", message: "تم حذف الحظر." });
  expect(rpc).toHaveBeenCalledWith("delete_availability_block_v1", { p_organization_id: "org-a", p_block_id: blockId, p_request_id: expect.any(String) });
});
