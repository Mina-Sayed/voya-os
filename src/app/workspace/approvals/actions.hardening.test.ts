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

import { decideBookingApprovalAction } from "./actions";

function form(values: Record<string, string>) {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

const idle = { status: "idle" as const, message: "" };

afterEach(() => vi.clearAllMocks());

test("rejects blank approval ids and unknown decisions before tenant lookup", async () => {
  await expect(decideBookingApprovalAction(idle, form({ approval_request_id: "", decision: "approved", reason: "مراجعة" })))
    .resolves.toMatchObject({ status: "invalid" });
  await expect(decideBookingApprovalAction(idle, form({ approval_request_id: "approval", decision: "maybe", reason: "مراجعة" })))
    .resolves.toMatchObject({ status: "invalid" });
  expect(mocks.loadMembership).not.toHaveBeenCalled();
});

test("keeps approval serialization failures retryable and observable", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
  const error = { code: "40001", message: "serialization failure" };
  mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error }) });

  await expect(decideBookingApprovalAction(idle, form({ approval_request_id: "approval", decision: "approved", reason: "مراجعة" })))
    .resolves.toEqual({ status: "retry", message: "تعذر حفظ قرار الاعتماد الآن." });
  expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.approval.booking.decide", error, expect.any(String));
});
