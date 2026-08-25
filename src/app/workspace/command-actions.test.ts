import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createServerClient: vi.fn(),
  loadMembership: vi.fn(),
  randomUUID: vi.fn(),
  reportFailure: vi.fn(),
  revalidatePath: vi.fn(),
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

import { createAvailabilityBlockAction } from "./availability/actions";
import { decideBookingApprovalAction } from "./approvals/actions";
import { createBookingDraftAction } from "./bookings/actions";
import { confirmBookingAction, recordBookingStayEventAction, requestBookingApprovalAction } from "./bookings/actions";
import { createClientAction } from "./clients/actions";
import { createLeadAction } from "./leads/actions";
import { createPropertyAction } from "./properties/actions";
import { createPropertyOwnerAction } from "./property-owners/actions";
import { createAiRunRequestAction } from "./ai/actions";
import { addWhatsappNoteAction, createWhatsappChannelAction, createWhatsappMessageAction } from "./whatsapp/actions";
import { createOperationsTaskAction, updateOperationsTaskStatusAction } from "./tasks/actions";
import { createTransportRequestAction } from "./transport/actions";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

function formData(values: Record<string, string>): FormData {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

const createCommandCases = [
  {
    name: "availability",
    operation: "workspace.availability.create",
    action: createAvailabilityBlockAction,
    data: formData({ property_id: "property", start_date: "2027-01-01", end_date: "2027-01-02", block_type: "maintenance", idempotency_key: "key" }),
    invalid: formData({ property_id: "property", start_date: "2027-01-02", end_date: "2027-01-01", block_type: "maintenance", idempotency_key: "key" }),
    denied: "لا تملك مساحة عمل نشطة.",
  },
  {
    name: "booking",
    operation: "workspace.booking.create",
    action: createBookingDraftAction,
    data: formData({ property_id: "property", client_id: "client", check_in: "2027-01-01", check_out: "2027-01-02", amount_minor: "2500000", currency: "EGP", idempotency_key: "key" }),
    invalid: formData({ property_id: "property", client_id: "client", check_in: "2027-01-02", check_out: "2027-01-01", amount_minor: "2500000", currency: "EGP", idempotency_key: "key" }),
    denied: "لا تملك مساحة عمل نشطة لإنشاء مسودة.",
  },
  {
    name: "client",
    operation: "workspace.client.create",
    action: createClientAction,
    data: formData({ display_name: "name", idempotency_key: "key" }),
    invalid: formData({ display_name: "", idempotency_key: "key" }),
    denied: "لا تملك مساحة عمل نشطة لإضافة عميل.",
  },
  {
    name: "lead",
    operation: "workspace.lead.create",
    action: createLeadAction,
    data: formData({ title: "title", source: "website", idempotency_key: "key" }),
    invalid: formData({ title: "", source: "website", idempotency_key: "key" }),
    denied: "لا تملك مساحة عمل نشطة.",
  },
  {
    name: "property",
    operation: "workspace.property.create",
    action: createPropertyAction,
    data: formData({ code: "CODE", name: "name", timezone: "Africa/Cairo", idempotency_key: "key" }),
    invalid: formData({ code: "CODE", name: "name", timezone: "", idempotency_key: "key" }),
    denied: "لا تملك مساحة عمل نشطة لإضافة عقار.",
  },
  {
    name: "property owner",
    operation: "workspace.property_owner.create",
    action: createPropertyOwnerAction,
    data: formData({ display_name: "name", idempotency_key: "key" }),
    invalid: formData({ display_name: "", idempotency_key: "key" }),
    denied: "لا تملك مساحة عمل نشطة لإضافة مالك.",
  },
] as const;

afterEach(() => vi.clearAllMocks());

describe("workspace create commands", () => {
  it.each([
    ["availability", "workspace.availability.create", createAvailabilityBlockAction, formData({ property_id: "property", start_date: "2027-01-01", end_date: "2027-01-02", block_type: "maintenance", idempotency_key: "key" })],
    ["booking", "workspace.booking.create", createBookingDraftAction, formData({ property_id: "property", client_id: "client", check_in: "2027-01-01", check_out: "2027-01-02", amount_minor: "2500000", currency: "EGP", idempotency_key: "key" })],
    ["client", "workspace.client.create", createClientAction, formData({ display_name: "name", idempotency_key: "key" })],
    ["lead", "workspace.lead.create", createLeadAction, formData({ title: "title", source: "website", idempotency_key: "key" })],
    ["property", "workspace.property.create", createPropertyAction, formData({ code: "CODE", name: "name", timezone: "Africa/Cairo", idempotency_key: "key" })],
    ["property owner", "workspace.property_owner.create", createPropertyOwnerAction, formData({ display_name: "name", idempotency_key: "key" })],
  ])("logs an unexpected %s RPC failure with its command request ID", async (_name, operation, action, data) => {
    const rpcError = { code: "XX000", message: "token=secret customer@example.com" };
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: rpcError });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await action({ status: "idle", message: "" }, data);

    const rpcRequestId = rpc.mock.calls[0]?.[1]?.p_request_id;
    expect(rpcRequestId).toEqual(expect.any(String));
    expect(mocks.reportFailure).toHaveBeenCalledWith(operation, rpcError, rpcRequestId);
  });

  it("keeps an unexpected lead provider failure retryable instead of treating it as invalid input", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpcError = { code: "XX000", message: "provider failure" };
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: rpcError }) });

    await expect(createLeadAction({ status: "idle", message: "" }, formData({ title: "title", source: "website", idempotency_key: "key" })))
      .resolves.toEqual({ status: "retry", message: "تعذر حفظ الطلب الآن. حاول مرة أخرى." });
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.lead.create", rpcError, expect.any(String));
  });

  it.each(createCommandCases)("rejects invalid $name input before loading tenant context", async ({ action, invalid }) => {
    await expect(action({ status: "idle", message: "" }, invalid)).resolves.toMatchObject({ status: "invalid" });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
    expect(mocks.createServerClient).not.toHaveBeenCalled();
  });

  it.each(createCommandCases)("denies $name when no active workspace exists", async ({ action, data, denied }) => {
    mocks.loadMembership.mockResolvedValue(null);
    await expect(action({ status: "idle", message: "" }, data)).resolves.toEqual({ status: "denied", message: denied });
    expect(mocks.createServerClient).not.toHaveBeenCalled();
    expect(mocks.reportFailure).not.toHaveBeenCalled();
    vi.clearAllMocks();
  });

  it.each(createCommandCases)("completes $name and revalidates its workspace route", async ({ action, data }) => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(action({ status: "idle", message: "" }, data)).resolves.toMatchObject({ status: "success" });
    expect(rpc).toHaveBeenCalledWith(expect.any(String), expect.objectContaining({ p_organization_id: "organization", p_request_id: expect.any(String) }));
    expect(mocks.revalidatePath).toHaveBeenCalledWith(expect.stringMatching(/^\/workspace\//));
    vi.clearAllMocks();
  });

  it.each(createCommandCases)("maps a permission failure for $name without logging it", async ({ action, data }) => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: { code: "42501", message: "permission denied" } });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(action({ status: "idle", message: "" }, data)).resolves.toMatchObject({ status: "denied" });
    expect(mocks.reportFailure).not.toHaveBeenCalled();
    vi.clearAllMocks();
  });

  it.each(createCommandCases)("returns retry and logs an unavailable provider for $name", async ({ action, data, operation }) => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockRejectedValue(new Error("provider unavailable"));

    await expect(action({ status: "idle", message: "" }, data)).resolves.toMatchObject({ status: "retry" });
    expect(mocks.reportFailure).toHaveBeenCalledWith(operation, expect.any(Error), expect.any(String));
    vi.clearAllMocks();
  });

  it.each(createCommandCases.filter(({ name }) => name !== "lead"))("maps missing Supabase configuration for $name", async ({ action, data }) => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockRejectedValue(new SupabaseConfigurationError());

    await expect(action({ status: "idle", message: "" }, data)).resolves.toEqual(expect.objectContaining({ status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." }));
    vi.clearAllMocks();
  });
});

describe("booking lifecycle commands", () => {
  it("rejects malformed lifecycle forms before loading tenant context", async () => {
    await expect(requestBookingApprovalAction({ status: "idle", message: "" }, formData({ booking_id: "", idempotency_key: "" })))
      .resolves.toEqual({ status: "invalid", message: "تعذر تحديد الحجز أو مفتاح المحاولة." });
    await expect(recordBookingStayEventAction({ status: "idle", message: "" }, formData({ booking_id: "booking", idempotency_key: "key", event_type: "handover" })))
      .resolves.toEqual({ status: "invalid", message: "نوع حدث الإقامة غير صالح." });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
  });

  it("maps lifecycle authorization errors without logging expected denials", async () => {
    mocks.loadMembership.mockResolvedValue(null);
    await expect(confirmBookingAction({ status: "idle", message: "" }, formData({ booking_id: "booking", idempotency_key: "key" })))
      .resolves.toEqual({ status: "denied", message: "لا تملك مساحة عمل نشطة." });
    expect(mocks.createServerClient).not.toHaveBeenCalled();
    expect(mocks.reportFailure).not.toHaveBeenCalled();
  });

  it("runs successful lifecycle commands with tenant context and revalidation", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(requestBookingApprovalAction({ status: "idle", message: "" }, formData({ booking_id: "booking", idempotency_key: "request-key" })))
      .resolves.toEqual({ status: "success", message: "تم إرسال الحجز التجاري إلى مسار الاعتماد." });
    expect(rpc).toHaveBeenCalledWith("request_commercial_booking_approval", expect.objectContaining({ p_organization_id: "organization", p_booking_id: "booking", p_idempotency_key: "request-key" }));
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/bookings");
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/approvals");
  });

  it("maps domain errors and logs only unexpected provider failures", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn()
      .mockResolvedValueOnce({ error: { code: "22023", message: "invalid state" } })
      .mockResolvedValueOnce({ error: { code: "XX000", message: "provider failure" } });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(confirmBookingAction({ status: "idle", message: "" }, formData({ booking_id: "booking", idempotency_key: "confirm-key" })))
      .resolves.toEqual({ status: "invalid", message: "لا يمكن تأكيد الحجز قبل اعتماد صالح أو بسبب تعارض في التوفر." });
    await expect(confirmBookingAction({ status: "idle", message: "" }, formData({ booking_id: "booking", idempotency_key: "confirm-key-2" })))
      .resolves.toEqual({ status: "retry", message: "تعذر تحديث دورة الحجز الآن." });
    expect(mocks.reportFailure).toHaveBeenCalledWith(expect.stringContaining("workspace.booking.confirm_commercial_booking"), expect.any(Object), expect.anything());
  });

  it("requires an eligible reviewer and a reason for approval decisions", async () => {
    await expect(decideBookingApprovalAction({ status: "idle", message: "" }, formData({ approval_request_id: "approval", decision: "approved", reason: "" })))
      .resolves.toEqual({ status: "invalid", message: "اكتب سبب القرار قبل الحفظ." });
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "sales_agent" });
    await expect(decideBookingApprovalAction({ status: "idle", message: "" }, formData({ approval_request_id: "approval", decision: "approved", reason: "مراجعة" })))
      .resolves.toEqual({ status: "denied", message: "قرارات الاعتماد متاحة لمالك المؤسسة والمدير فقط." });
  });

  it("completes approval decisions and maps permission and provider failures", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    const rpc = vi.fn()
      .mockResolvedValueOnce({ error: null })
      .mockResolvedValueOnce({ error: { code: "42501", message: "denied" } })
      .mockResolvedValueOnce({ error: { code: "XX000", message: "provider" } });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(decideBookingApprovalAction({ status: "idle", message: "" }, formData({ approval_request_id: "approval", decision: "approved", reason: "مراجعة" })))
      .resolves.toEqual({ status: "success", message: "تم اعتماد طلب الحجز." });
    await expect(decideBookingApprovalAction({ status: "idle", message: "" }, formData({ approval_request_id: "approval", decision: "approved", reason: "مراجعة" })))
      .resolves.toEqual({ status: "denied", message: "لا تملك صلاحية اتخاذ هذا القرار." });
    await expect(decideBookingApprovalAction({ status: "idle", message: "" }, formData({ approval_request_id: "approval", decision: "approved", reason: "مراجعة" })))
      .resolves.toEqual({ status: "retry", message: "تعذر حفظ قرار الاعتماد الآن." });
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/approvals");
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.approval.booking.decide", expect.any(Object), expect.any(String));
  });

  it.each([
    ["approved", "تم اعتماد طلب الحجز."],
    ["rejected", "تم رفض طلب الحجز."],
  ] as const)("returns action-neutral feedback for a %s booking approval decision", async (decision, message) => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: null }) });

    await expect(decideBookingApprovalAction({ status: "idle", message: "" }, formData({ approval_request_id: "approval", decision, reason: "مراجعة" })))
      .resolves.toEqual({ status: "success", message });
  });

  it.each([
    ["check_in", "تم تسجيل الوصول."],
    ["check_out", "تم تسجيل المغادرة وإكمال الإقامة."],
  ] as const)("records a successful %s stay event", async (eventType, message) => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(recordBookingStayEventAction({ status: "idle", message: "" }, formData({ booking_id: "booking", idempotency_key: "key", event_type: eventType, notes: "notes" })))
      .resolves.toEqual({ status: "success", message });
    expect(rpc).toHaveBeenCalledWith("record_commercial_booking_stay_event", expect.objectContaining({ p_event_type: eventType, p_notes: "notes", p_organization_id: "organization" }));
    vi.clearAllMocks();
  });
});

describe("extended operations commands", () => {
  it("rejects malformed optional task dates before loading the tenant context", async () => {
    await expect(createOperationsTaskAction({ status: "idle", message: "" }, formData({
      task_type: "inspection",
      title: "فحص",
      due_at: "not-a-date",
      idempotency_key: "task-key",
    }))).resolves.toEqual({ status: "invalid", message: "تحقق من تاريخ استحقاق المهمة." });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
  });

  it("rejects malformed transport timestamps before loading the tenant context", async () => {
    await expect(createTransportRequestAction({ status: "idle", message: "" }, formData({
      request_type: "airport_transfer",
      guest_label: "ضيف",
      pickup_location: "المطار",
      dropoff_location: "العقار",
      pickup_at: "not-a-date",
      passenger_count: "2",
      idempotency_key: "transport-key",
    }))).resolves.toEqual({ status: "invalid", message: "تحقق من توقيت طلب النقل." });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
  });

  it("creates a task with a normalized due date and maps task RPC outcomes", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(createOperationsTaskAction({ status: "idle", message: "" }, formData({
      task_type: "inspection",
      title: "فحص",
      due_at: "2027-01-01T12:30:00Z",
      idempotency_key: "task-key",
    }))).resolves.toMatchObject({ status: "success" });
    expect(rpc).toHaveBeenCalledWith("create_operations_task", expect.objectContaining({ p_due_at: "2027-01-01T12:30:00.000Z" }));
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/tasks");

    for (const [code, status] of [["42501", "denied"], ["22023", "invalid"], ["XX000", "retry"]] as const) {
      vi.clearAllMocks();
      mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
      mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code } }) });
      await expect(createOperationsTaskAction({ status: "idle", message: "" }, formData({ task_type: "inspection", title: "فحص", idempotency_key: `task-${code}` })))
        .resolves.toMatchObject({ status });
    }
  });

  it("denies task creation for an ineligible role and reports task dependency failures", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "viewer" });
    await expect(createOperationsTaskAction({ status: "idle", message: "" }, formData({ task_type: "inspection", title: "فحص", idempotency_key: "task-key" })))
      .resolves.toMatchObject({ status: "denied" });

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    mocks.createServerClient.mockRejectedValue(new Error("provider unavailable"));
    await expect(createOperationsTaskAction({ status: "idle", message: "" }, formData({ task_type: "inspection", title: "فحص", idempotency_key: "task-key" })))
      .resolves.toMatchObject({ status: "retry" });
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.task.create", expect.any(Error), expect.any(String));
  });

  it("updates task status with expected errors ignored and unexpected errors logged", async () => {
    mocks.loadMembership.mockResolvedValue(null);
    await expect(updateOperationsTaskStatusAction("task", "done")).resolves.toBeUndefined();
    expect(mocks.createServerClient).not.toHaveBeenCalled();

    for (const error of [null, { code: "42501" }, { code: "22023" }, { code: "23503" }, { code: "XX000" }]) {
      vi.clearAllMocks();
      mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
      mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error }) });
      await expect(updateOperationsTaskStatusAction("task", "done")).resolves.toBeUndefined();
      expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/tasks");
      if (error?.code === "XX000") expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.task.status", error, expect.any(String));
    }

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    mocks.createServerClient.mockRejectedValue(new Error("provider unavailable"));
    await expect(updateOperationsTaskStatusAction("task", "done")).resolves.toBeUndefined();
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.task.status", expect.any(Error), expect.any(String));
  });

  it("covers fleet vehicle, driver, and transport request command boundaries", async () => {
    const validVehicle = formData({ display_name: "فان", vehicle_type: "van", registration_code: "EG-1", passenger_capacity: "7", idempotency_key: "vehicle-key" });
    const validDriver = formData({ display_name: "سائق", phone_e164: "+201000000000", idempotency_key: "driver-key" });
    const validRequest = formData({ request_type: "airport_transfer", guest_label: "ضيف", pickup_location: "المطار", dropoff_location: "العقار", pickup_at: "2027-01-01T12:30:00Z", return_at: "2027-01-01T18:00:00Z", passenger_count: "2", idempotency_key: "request-key" });

    await expect((await import("./transport/actions")).createFleetVehicleAction({ status: "idle", message: "" }, formData({ display_name: "", vehicle_type: "van", registration_code: "", passenger_capacity: "x" })))
      .resolves.toMatchObject({ status: "invalid" });
    await expect((await import("./transport/actions")).createFleetDriverAction({ status: "idle", message: "" }, formData({ display_name: "" })))
      .resolves.toMatchObject({ status: "invalid" });

    const transportModule = await import("./transport/actions");
    for (const [action, data, role] of [
      [transportModule.createFleetVehicleAction, validVehicle, "operations"],
      [transportModule.createFleetDriverAction, validDriver, "operations"],
      [transportModule.createTransportRequestAction, validRequest, "sales_agent"],
    ] as const) {
      vi.clearAllMocks();
      mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role });
      const rpc = vi.fn().mockResolvedValue({ error: null });
      mocks.createServerClient.mockResolvedValue({ rpc });
      await expect(action({ status: "idle", message: "" }, data)).resolves.toMatchObject({ status: "success" });
      expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/transport");
    }

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "viewer" });
    await expect(transportModule.createFleetVehicleAction({ status: "idle", message: "" }, validVehicle)).resolves.toMatchObject({ status: "denied" });
    await expect(transportModule.createFleetDriverAction({ status: "idle", message: "" }, validDriver)).resolves.toMatchObject({ status: "denied" });
    await expect(transportModule.createTransportRequestAction({ status: "idle", message: "" }, validRequest)).resolves.toMatchObject({ status: "denied" });
  });

  it("maps transport RPC failures and protects assignment/status updates", async () => {
    const transportModule = await import("./transport/actions");
    const validVehicle = formData({ display_name: "فان", vehicle_type: "van", registration_code: "EG-1", passenger_capacity: "7", idempotency_key: "vehicle-key-errors" });
    const validDriver = formData({ display_name: "سائق", phone_e164: "+201000000000", idempotency_key: "driver-key-errors" });
    const validRequest = formData({ request_type: "airport_transfer", guest_label: "ضيف", pickup_location: "المطار", dropoff_location: "العقار", pickup_at: "2027-01-01T12:30:00Z", passenger_count: "2", idempotency_key: "request-key" });
    for (const [action, data] of [
      [transportModule.createFleetVehicleAction, validVehicle],
      [transportModule.createFleetDriverAction, validDriver],
      [transportModule.createTransportRequestAction, validRequest],
    ] as const) {
      for (const [code, status] of [["42501", "denied"], ["22023", "invalid"], ["XX000", "retry"]] as const) {
        vi.clearAllMocks();
        mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
        mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code } }) });
        await expect(action({ status: "idle", message: "" }, data)).resolves.toMatchObject({ status });
      }
    }

    vi.clearAllMocks();
    await expect(transportModule.assignTransportRequestAction({ status: "idle", message: "" }, formData({ request_id: "" }))).resolves.toMatchObject({ status: "invalid" });
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: null }) });
    await expect(transportModule.assignTransportRequestAction({ status: "idle", message: "" }, formData({ request_id: "request", vehicle_id: "vehicle", driver_id: "driver" }))).resolves.toMatchObject({ status: "success" });

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    mocks.createServerClient.mockRejectedValue(new Error("provider unavailable"));
    await expect(transportModule.assignTransportRequestAction({ status: "idle", message: "" }, formData({ request_id: "request" }))).resolves.toMatchObject({ status: "retry" });
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.transport.request.assign", expect.any(Error), expect.any(String));

    for (const [code, status] of [["42501", "denied"], ["22023", "invalid"], ["23P01", "invalid"], ["XX000", "retry"]] as const) {
      vi.clearAllMocks();
      mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
      const error = { code, message: "provider detail" };
      mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error }) });
      await expect(transportModule.assignTransportRequestAction({ status: "idle", message: "" }, formData({ request_id: "request" }))).resolves.toMatchObject({ status });
      if (status === "retry") expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.transport.request.assign", error, expect.any(String));
    }

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    mocks.createServerClient.mockRejectedValue(new Error("provider unavailable"));
    await expect(transportModule.createTransportRequestAction({ status: "idle", message: "" }, validRequest)).resolves.toMatchObject({ status: "retry" });
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.transport.request.create", expect.any(Error), expect.any(String));

    for (const error of [null, { code: "42501" }, { code: "22023" }, { code: "23503" }, { code: "XX000" }]) {
      vi.clearAllMocks();
      mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
      mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error }) });
      const expectedStatus = error === null ? "success" : error.code === "42501" ? "denied" : ["22023", "23503"].includes(error.code) ? "invalid" : "retry";
      await expect(transportModule.updateTransportRequestStatusAction("request", "assigned")).resolves.toMatchObject({ status: expectedStatus });
      if (expectedStatus === "success") expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/transport");
      else expect(mocks.revalidatePath).not.toHaveBeenCalled();
      if (error?.code === "XX000") expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.transport.request.status", error, expect.any(String));
    }

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    mocks.createServerClient.mockRejectedValue(new Error("provider unavailable"));
    await expect(transportModule.updateTransportRequestStatusAction("request", "assigned")).resolves.toMatchObject({ status: "retry" });
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.transport.request.status", expect.any(Error), expect.any(String));
  });
});

describe("AI and WhatsApp commands", () => {
  const aiData = formData({ agent_kind: "sales", purpose: "لخص الطلبات", idempotency_key: "ai-key" });
  const channelData = formData({ provider: "meta_cloud_sandbox", external_channel_id: "channel", display_name: "قناة الاختبار" });
  const messageData = formData({ conversation_id: "conversation", body_text: "مرحباً", idempotency_key: "message-key" });
  const noteData = formData({ conversation_id: "conversation", note_text: "ملاحظة داخلية" });

  it("validates and records an AI run request without enabling provider execution", async () => {
    await expect(createAiRunRequestAction({ status: "idle", message: "" }, formData({ agent_kind: "", purpose: "", idempotency_key: "" })))
      .resolves.toMatchObject({ status: "invalid" });
    mocks.loadMembership.mockResolvedValue(null);
    await expect(createAiRunRequestAction({ status: "idle", message: "" }, aiData)).resolves.toMatchObject({ status: "denied" });

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });
    await expect(createAiRunRequestAction({ status: "idle", message: "" }, aiData)).resolves.toMatchObject({ status: "success" });
    expect(rpc).toHaveBeenCalledWith("create_ai_run_request", expect.objectContaining({ p_organization_id: "organization", p_agent_kind: "sales", p_idempotency_key: "ai-key" }));
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/ai");
  });

  it("maps AI RPC errors and dependency failures safely", async () => {
    for (const [code, status] of [["42501", "denied"], ["22023", "invalid"], ["XX000", "retry"]] as const) {
      vi.clearAllMocks();
      mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
      const error = { code, message: "provider detail" };
      mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error }) });
      await expect(createAiRunRequestAction({ status: "idle", message: "" }, aiData)).resolves.toMatchObject({ status });
      if (status === "retry") expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.ai.run.request", error, expect.any(String));
    }

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    mocks.createServerClient.mockRejectedValue(new Error("provider unavailable"));
    await expect(createAiRunRequestAction({ status: "idle", message: "" }, aiData)).resolves.toMatchObject({ status: "retry" });
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.ai.run.request", expect.any(Error), expect.any(String));
  });

  it("validates and records WhatsApp channel, message, and note commands", async () => {
    await expect(createWhatsappChannelAction({ status: "idle", message: "" }, formData({ provider: "", external_channel_id: "", display_name: "" }))).resolves.toMatchObject({ status: "invalid" });
    await expect(createWhatsappMessageAction({ status: "idle", message: "" }, formData({ conversation_id: "", body_text: "", idempotency_key: "" }))).resolves.toMatchObject({ status: "invalid" });
    await expect(addWhatsappNoteAction({ status: "idle", message: "" }, formData({ conversation_id: "", note_text: "" }))).resolves.toMatchObject({ status: "invalid" });

    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "viewer" });
    await expect(createWhatsappChannelAction({ status: "idle", message: "" }, channelData)).resolves.toMatchObject({ status: "denied" });
    mocks.loadMembership.mockResolvedValue(null);
    await expect(createWhatsappMessageAction({ status: "idle", message: "" }, messageData)).resolves.toMatchObject({ status: "denied" });
    await expect(addWhatsappNoteAction({ status: "idle", message: "" }, noteData)).resolves.toMatchObject({ status: "denied" });

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });
    await expect(createWhatsappChannelAction({ status: "idle", message: "" }, channelData)).resolves.toMatchObject({ status: "success" });
    await expect(createWhatsappMessageAction({ status: "idle", message: "" }, messageData)).resolves.toMatchObject({ status: "success" });
    await expect(addWhatsappNoteAction({ status: "idle", message: "" }, noteData)).resolves.toMatchObject({ status: "success" });
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/whatsapp");
  });

  it("maps WhatsApp expected errors and logs only unexpected provider failures", async () => {
    const cases = [
      [createWhatsappChannelAction, channelData, "workspace.whatsapp.channel.create"],
      [createWhatsappMessageAction, messageData, "workspace.whatsapp.message.create"],
      [addWhatsappNoteAction, noteData, "workspace.whatsapp.note.create"],
    ] as const;
    for (const [action, data, operation] of cases) {
      for (const [code, status] of [["42501", "denied"], ["22023", "invalid"], ["XX000", "retry"]] as const) {
        vi.clearAllMocks();
        mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
        const error = { code, message: "provider detail" };
        mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error }) });
        await expect(action({ status: "idle", message: "" }, data)).resolves.toMatchObject({ status });
        if (status === "retry") expect(mocks.reportFailure).toHaveBeenCalledWith(operation, error, expect.any(String));
      }
    }

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    mocks.createServerClient.mockRejectedValue(new Error("provider unavailable"));
    await expect(createWhatsappChannelAction({ status: "idle", message: "" }, channelData)).resolves.toMatchObject({ status: "retry" });
    await expect(createWhatsappMessageAction({ status: "idle", message: "" }, messageData)).resolves.toMatchObject({ status: "retry" });
    await expect(addWhatsappNoteAction({ status: "idle", message: "" }, noteData)).resolves.toMatchObject({ status: "retry" });
    expect(mocks.reportFailure).toHaveBeenCalledTimes(3);
  });
});
