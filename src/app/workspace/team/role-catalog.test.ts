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

import { teamMemberCommandAction } from "./actions";

function form(role: string) {
  const data = new FormData();
  data.set("command", "change_role");
  data.set("membership_id", "member-1");
  data.set("role", role);
  return data;
}

afterEach(() => vi.clearAllMocks());

test.each(["sales_agent", "operations", "accountant"])("allows owner to provision the runtime %s role", async (role) => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });

  const result = await teamMemberCommandAction({ status: "idle", message: "" }, form(role));

  expect(result).toEqual({ status: "success", message: "تم تحديث دور العضو." });
  expect(rpc).toHaveBeenCalledWith("change_organization_member_role", expect.objectContaining({
    p_organization_id: "organization",
    p_membership_id: "member-1",
    p_role: role,
  }));
});
