import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createServerClient: vi.fn(),
  loadMembership: vi.fn(),
  reportFailure: vi.fn(),
  revalidatePath: vi.fn(),
  randomUUID: vi.fn(() => "request-id"),
}));

vi.mock("node:crypto", async (importOriginal) => ({
  ...(await importOriginal<typeof import("node:crypto")>()),
  randomUUID: mocks.randomUUID,
}));
vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createServerClient }));

import { createOperationsTaskAction, updateOperationsTaskStatusAction } from "./actions";

function formData(values: Record<string, string>): FormData {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

function clientWithOrganizationTimezone(rpc: ReturnType<typeof vi.fn>) {
  const maybeSingle = vi.fn().mockResolvedValue({ data: { timezone: "Africa/Cairo" }, error: null });
  const from = vi.fn(() => ({ select: vi.fn(() => ({ eq: vi.fn(() => ({ maybeSingle })) })) }));
  return { from, rpc };
}

const idle = { status: "idle" as const, message: "" };
const taskData = {
  task_type: "cleaning",
  title: "تجهيز الوحدة",
  description: "مراجعة المفاتيح",
  due_at: "2026-08-14T10:30",
  assigned_membership_id: "member-operator",
  idempotency_key: "task-1",
};

afterEach(() => vi.clearAllMocks());

describe("operations task action", () => {
  it("rejects incomplete input before loading tenant context", async () => {
    await expect(createOperationsTaskAction(idle, formData({ task_type: "cleaning", title: "", idempotency_key: "task-1" })))
      .resolves.toEqual({ status: "invalid", message: "أكمل نوع المهمة والعنوان." });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
    expect(mocks.createServerClient).not.toHaveBeenCalled();
  });

  it.each(["owner", "manager", "operations"] as const)("allows %s to create an assigned task through the tenant RPC", async (role) => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue(clientWithOrganizationTimezone(rpc));

    await expect(createOperationsTaskAction(idle, formData(taskData)))
      .resolves.toEqual({ status: "success", message: "تمت إضافة المهمة." });

    expect(rpc).toHaveBeenCalledWith("create_operations_task", expect.objectContaining({
      p_organization_id: "organization",
      p_task_type: "cleaning",
      p_title: "تجهيز الوحدة",
      p_description: "مراجعة المفاتيح",
      p_due_at: "2026-08-14T07:30:00.000Z",
      p_booking_id: null,
      p_assigned_membership_id: "member-operator",
      p_idempotency_key: "task-1",
      p_request_id: expect.any(String),
    }));
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/tasks");
    vi.clearAllMocks();
  });

  it("denies a viewer without opening a Supabase client", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "viewer" });

    await expect(createOperationsTaskAction(idle, formData(taskData)))
      .resolves.toEqual({ status: "denied", message: "إضافة المهام متاحة لفريق التشغيل والمدير فقط." });
    expect(mocks.createServerClient).not.toHaveBeenCalled();
  });

  it("logs unexpected RPC errors with a request id and returns a generic retry state", async () => {
    const error = { code: "XX000", message: "provider secret" };
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    mocks.createServerClient.mockResolvedValue(clientWithOrganizationTimezone(vi.fn().mockResolvedValue({ error })));

    await expect(createOperationsTaskAction(idle, formData(taskData)))
      .resolves.toEqual({ status: "retry", message: "تعذر حفظ المهمة الآن." });
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.task.create", error, expect.any(String));
  });
});

describe("operations task status action", () => {
  it("rejects an unknown status before loading tenant context", async () => {
    await expect(updateOperationsTaskStatusAction("task-1", "done"))
      .resolves.toEqual({ status: "invalid", message: "حالة المهمة غير صالحة." });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
    expect(mocks.createServerClient).not.toHaveBeenCalled();
  });

  it("denies when there is no active membership", async () => {
    mocks.loadMembership.mockResolvedValue(null);
    await expect(updateOperationsTaskStatusAction("task-1", "completed"))
      .resolves.toEqual({ status: "denied", message: "تحديث المهام متاح لفريق التشغيل والمدير فقط." });
    expect(mocks.createServerClient).not.toHaveBeenCalled();
  });

  it("maps RPC outcomes to explicit states and revalidates only on success", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });

    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: null }) });
    await expect(updateOperationsTaskStatusAction("task-1", "completed"))
      .resolves.toEqual({ status: "success", message: "تم تحديث حالة المهمة." });
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/tasks");

    for (const [code, status] of [["42501", "denied"], ["22023", "invalid"], ["23503", "invalid"]] as const) {
      vi.clearAllMocks();
      mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
      mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code } }) });
      await expect(updateOperationsTaskStatusAction("task-1", "completed")).resolves.toMatchObject({ status });
      expect(mocks.revalidatePath).not.toHaveBeenCalled();
    }

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    const error = { code: "XX000", message: "boom" };
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error }) });
    await expect(updateOperationsTaskStatusAction("task-1", "completed"))
      .resolves.toEqual({ status: "retry", message: "تعذر تحديث حالة المهمة الآن." });
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.task.status", error, expect.any(String));
    expect(mocks.revalidatePath).not.toHaveBeenCalled();
  });
});
