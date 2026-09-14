import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  createServerClient: vi.fn(),
  reportFailure: vi.fn(),
  revalidatePath: vi.fn(),
  randomUUID: vi.fn(() => "request-id"),
  randomBytes: vi.fn(() => Buffer.alloc(32, 0xab)),
}));

vi.mock("node:crypto", async (importOriginal) => ({
  ...(await importOriginal<typeof import("node:crypto")>()),
  randomUUID: mocks.randomUUID,
  randomBytes: mocks.randomBytes,
}));
vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createServerClient }));

import { inviteTeamMemberAction } from "./actions";

function formData(values: Record<string, string>): FormData {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

const idle = { status: "idle" as const, message: "" };

afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("team error classification", () => {
  it.each(["22001", "22003", "22023", "22P02", "23503", "23505", "23514"])(
    "maps deterministic input/constraint error %s to invalid",
    async (code) => {
      vi.stubEnv("OUTBOX_PAYLOAD_ENCRYPTION_KEY", Buffer.alloc(32, 7).toString("base64"));
      mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
      mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code, message: "provider detail" } }) });

      await expect(inviteTeamMemberAction(idle, formData({ email: "new@example.com", role: "viewer" })))
        .resolves.toMatchObject({ status: "invalid" });
      expect(mocks.reportFailure).not.toHaveBeenCalled();
    },
  );

  it("keeps serialization failures retryable and observable", async () => {
    vi.stubEnv("OUTBOX_PAYLOAD_ENCRYPTION_KEY", Buffer.alloc(32, 7).toString("base64"));
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const error = { code: "40001", message: "serialization failure" };
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error }) });

    await expect(inviteTeamMemberAction(idle, formData({ email: "new@example.com", role: "viewer" })))
      .resolves.toEqual({ status: "retry", message: "تعذر إنشاء الدعوة الآن. حاول مرة أخرى." });
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.team.invite", error, expect.any(String));
  });
});
