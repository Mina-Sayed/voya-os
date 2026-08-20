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

import { inviteTeamMemberAction, teamMemberCommandAction } from "./actions";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

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

describe("team invitation action", () => {
  it("rejects invalid invitation input before loading workspace context", async () => {
    await expect(inviteTeamMemberAction(idle, formData({ email: "not-an-email", role: "manager" })))
      .resolves.toEqual({ status: "invalid", message: "اكتب بريدًا صحيحًا واختر دورًا صالحًا." });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
    expect(mocks.createServerClient).not.toHaveBeenCalled();
  });

  it("generates the one-time token on the server and sends only its RPC boundary value", async () => {
    vi.stubEnv("OUTBOX_PAYLOAD_ENCRYPTION_KEY", Buffer.alloc(32, 7).toString("base64"));
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ data: "invitation-id", error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(inviteTeamMemberAction(idle, formData({ email: " New@Example.com ", role: "operator" })))
      .resolves.toEqual({ status: "success", message: "تم إنشاء الدعوة وستُرسل عبر قناة البريد المعتمدة." });

    expect(rpc).toHaveBeenCalledWith("invite_organization_member_v1", {
      p_organization_id: "organization",
      p_email: "new@example.com",
      p_role: "operator",
      p_token_digest: expect.stringMatching(/^[0-9a-f]{64}$/),
      p_sealed_token: expect.stringMatching(/^v1\.[^.]+\.[^.]+\.[^.]+$/),
      p_request_id: expect.any(String),
    });
    const invitationCall = rpc.mock.calls[0]?.[1] as Record<string, string>;
    expect(invitationCall.p_sealed_token).not.toContain(invitationCall.p_token_digest);
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/team");
  });

  it("maps permission and provider failures without exposing provider details", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code: "42501", message: "denied" } }) });
    await expect(inviteTeamMemberAction(idle, formData({ email: "new@example.com", role: "viewer" })))
      .resolves.toMatchObject({ status: "denied" });
    expect(mocks.reportFailure).not.toHaveBeenCalled();

    vi.clearAllMocks();
    vi.stubEnv("OUTBOX_PAYLOAD_ENCRYPTION_KEY", Buffer.alloc(32, 7).toString("base64"));
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const providerError = { code: "XX000", message: "provider secret" };
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: providerError }) });
    await expect(inviteTeamMemberAction(idle, formData({ email: "new@example.com", role: "viewer" })))
      .resolves.toEqual({ status: "retry", message: "تعذر إنشاء الدعوة الآن. حاول مرة أخرى." });
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.team.invite", providerError, expect.any(String));
  });
});

describe("team lifecycle action", () => {
  it("routes a role change through the matching server RPC", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(teamMemberCommandAction(idle, formData({
      command: "change_role",
      membership_id: "membership",
      role: "manager",
    }))).resolves.toEqual({ status: "success", message: "تم تحديث دور العضو." });

    expect(rpc).toHaveBeenCalledWith("change_organization_member_role", {
      p_organization_id: "organization",
      p_membership_id: "membership",
      p_role: "manager",
      p_request_id: expect.any(String),
    });
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/team");
  });

  it("requires a reason for suspension/removal and never loads context for malformed commands", async () => {
    await expect(teamMemberCommandAction(idle, formData({ command: "remove", membership_id: "membership" })))
      .resolves.toEqual({ status: "invalid", message: "اكتب سبب الإجراء قبل الحفظ." });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
  });

  it.each([
    ["suspend", { command: "suspend", membership_id: "membership", reason: "إيقاف مؤقت" }, "suspend_organization_member", "تم تعليق العضو."],
    ["reactivate", { command: "reactivate", membership_id: "membership" }, "reactivate_organization_member", "تمت إعادة تفعيل العضو."],
    ["remove", { command: "remove", membership_id: "membership", reason: "لم يعد ضمن الفريق" }, "remove_organization_member", "تمت إزالة العضو."],
    ["revoke invitation", { command: "revoke_invitation", invitation_id: "invitation" }, "revoke_organization_invitation", "تم إلغاء الدعوة."],
    ["resend invitation", { command: "resend_invitation", invitation_id: "invitation" }, "resend_organization_invitation_v1", "تمت جدولة إعادة إرسال الدعوة."],
  ] as const)("routes %s through its dedicated RPC", async (_name, values, rpcName, message) => {
    vi.clearAllMocks();
    if (values.command === "resend_invitation") vi.stubEnv("OUTBOX_PAYLOAD_ENCRYPTION_KEY", Buffer.alloc(32, 7).toString("base64"));
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(teamMemberCommandAction(idle, formData(values))).resolves.toEqual({ status: "success", message });
    expect(rpc).toHaveBeenCalledWith(rpcName, expect.objectContaining({ p_organization_id: "organization", p_request_id: expect.any(String) }));
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/team");
  });

  it("denies non-owner lifecycle commands and fails closed when invitation sealing is unavailable", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    await expect(teamMemberCommandAction(idle, formData({ command: "reactivate", membership_id: "membership" })))
      .resolves.toEqual({ status: "denied", message: "إجراءات الفريق متاحة لمالك المؤسسة فقط." });

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    vi.stubEnv("OUTBOX_PAYLOAD_ENCRYPTION_KEY", "");
    await expect(teamMemberCommandAction(idle, formData({ command: "resend_invitation", invitation_id: "invitation" })))
      .resolves.toEqual({ status: "retry", message: "الخدمة غير مهيأة لإرسال دعوات الفريق." });
    expect(mocks.createServerClient).not.toHaveBeenCalled();
  });

  it("maps lifecycle RPC denials and unexpected failures safely", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn()
      .mockResolvedValueOnce({ error: { code: "42501", message: "denied" } })
      .mockResolvedValueOnce({ error: { code: "XX000", message: "provider detail" } });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(teamMemberCommandAction(idle, formData({ command: "reactivate", membership_id: "membership" })))
      .resolves.toEqual({ status: "denied", message: "لا تملك صلاحية إدارة الفريق." });
    await expect(teamMemberCommandAction(idle, formData({ command: "reactivate", membership_id: "membership" })))
      .resolves.toEqual({ status: "retry", message: "تعذر تنفيذ إجراء الفريق الآن. حاول مرة أخرى." });
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.team.reactivate", expect.any(Object), expect.any(String));
  });

  it("rejects malformed invitation targets before loading the workspace", async () => {
    await expect(teamMemberCommandAction(idle, formData({ command: "revoke_invitation" })))
      .resolves.toEqual({ status: "invalid", message: "تعذر تحديد الدعوة." });
    await expect(teamMemberCommandAction(idle, formData({ command: "change_role", membership_id: "membership", role: "superuser" })))
      .resolves.toEqual({ status: "invalid", message: "دور الفريق غير صالح." });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
  });

  it("maps team dependency failures to safe retry messages", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockRejectedValueOnce(new SupabaseConfigurationError());
    await expect(teamMemberCommandAction(idle, formData({ command: "reactivate", membership_id: "membership" })))
      .resolves.toEqual({ status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." });

    mocks.createServerClient.mockRejectedValueOnce(new Error("provider secret"));
    await expect(teamMemberCommandAction(idle, formData({ command: "reactivate", membership_id: "membership" })))
      .resolves.toEqual({ status: "retry", message: "تعذر تنفيذ إجراء الفريق الآن. حاول مرة أخرى." });
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.team.reactivate", expect.any(Error), expect.any(String));
  });
});
