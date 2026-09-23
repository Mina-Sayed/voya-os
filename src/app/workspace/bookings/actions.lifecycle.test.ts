import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  createServerClient: vi.fn(),
  revalidatePath: vi.fn(),
  reportFailure: vi.fn(),
}));

vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createServerClient }));
vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));

import { requestBookingApprovalAction } from "./actions";

afterEach(() => vi.clearAllMocks());

function formData() {
  const data = new FormData();
  data.set("booking_id", "booking-id");
  data.set("idempotency_key", "approval-key");
  return data;
}

describe("requestBookingApprovalAction operational readiness", () => {
  it("guides a sole owner to invite a second owner/manager instead of reporting no permission", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({
      rpc: vi.fn().mockResolvedValue({
        data: null,
        error: { code: "42501", message: "APPROVAL_NOT_OPERATIONALLY_READY" },
      }),
    });

    await expect(requestBookingApprovalAction({ status: "idle", message: "" }, formData())).resolves.toEqual({
      status: "invalid",
      message: "تعذر طلب الاعتماد: تحتاج المؤسسة إلى مالك أو مدير ثانٍ قبل أول موافقة تشغيلية. ادعُ عضوًا إداريًا ثم أعد المحاولة.",
    });
  });

  it("keeps reporting genuine permission denial as denied", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({
      rpc: vi.fn().mockResolvedValue({
        data: null,
        error: { code: "42501", message: "commercial booking approval request is not permitted" },
      }),
    });

    await expect(requestBookingApprovalAction({ status: "idle", message: "" }, formData())).resolves.toEqual({
      status: "denied",
      message: "لا تملك صلاحية طلب اعتماد.",
    });
  });
});
