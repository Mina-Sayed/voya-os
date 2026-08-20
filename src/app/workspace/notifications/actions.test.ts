import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  reportFailure: vi.fn(),
  revalidatePath: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: vi.fn().mockResolvedValue({ rpc: mocks.rpc }),
}));

import { markNotificationReadAction } from "./actions";

afterEach(() => vi.clearAllMocks());

describe("markNotificationReadAction", () => {
  it("marks a tenant-owned notification as read without throwing at runtime", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.rpc.mockResolvedValue({ error: null });

    await expect(markNotificationReadAction("notification")).resolves.toBeUndefined();

    expect(mocks.rpc).toHaveBeenCalledWith("mark_notification_read", {
      p_organization_id: "organization",
      p_notification_id: "notification",
    });
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/notifications");
  });

  it("reports unexpected provider failures without exposing them to the caller", async () => {
    const providerError = { code: "XX000", message: "provider detail" };
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.rpc.mockResolvedValue({ error: providerError });

    await expect(markNotificationReadAction("notification")).resolves.toBeUndefined();
    expect(mocks.reportFailure).toHaveBeenCalledWith(
      "workspace.notification.read",
      providerError,
      expect.any(String),
    );
    expect(mocks.revalidatePath).not.toHaveBeenCalled();
  });
});
