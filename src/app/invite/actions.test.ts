import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  reportFailure: vi.fn(),
  rpc: vi.fn(),
  getUser: vi.fn(),
}));

vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: vi.fn().mockResolvedValue({ auth: { getUser: mocks.getUser }, rpc: mocks.rpc }),
}));

import { acceptOrganizationInvitationAction } from "./actions";

const token = "a".repeat(64);

afterEach(() => vi.clearAllMocks());

describe("acceptOrganizationInvitationAction", () => {
  it("accepts a valid invitation through the tenant RPC", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.rpc.mockResolvedValue({ error: null });
    const formData = new FormData();
    formData.set("token", token);

    await expect(acceptOrganizationInvitationAction({ status: "idle", message: "" }, formData))
      .resolves.toEqual({ status: "success", message: "تم قبول الدعوة. جارٍ فتح مساحة العمل…" });
    expect(mocks.rpc).toHaveBeenCalledWith("accept_organization_invitation", {
      p_token_digest: token,
      p_request_id: expect.any(String),
    });
  });

  it("rejects malformed tokens before contacting the session or database", async () => {
    const formData = new FormData();
    formData.set("token", "not-a-token");

    await expect(acceptOrganizationInvitationAction({ status: "idle", message: "" }, formData))
      .resolves.toEqual({ status: "invalid", message: "رابط الدعوة غير صالح." });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("requires an authenticated user when no workspace context is ready", async () => {
    mocks.loadMembership.mockResolvedValue(null);
    mocks.getUser.mockResolvedValue({ data: { user: null }, error: null });
    const formData = new FormData();
    formData.set("token", token);

    await expect(acceptOrganizationInvitationAction({ status: "idle", message: "" }, formData))
      .resolves.toEqual({ status: "denied", message: "سجّل الدخول بالبريد المرتبط بالدعوة أولًا." });
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
