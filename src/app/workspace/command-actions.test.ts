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
    data: formData({ property_id: "property", client_id: "client", check_in: "2027-01-01", check_out: "2027-01-02", idempotency_key: "key" }),
    invalid: formData({ property_id: "property", client_id: "client", check_in: "2027-01-02", check_out: "2027-01-01", idempotency_key: "key" }),
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
    ["booking", "workspace.booking.create", createBookingDraftAction, formData({ property_id: "property", client_id: "client", check_in: "2027-01-01", check_out: "2027-01-02", idempotency_key: "key" })],
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
      .resolves.toEqual({ status: "success", message: "تم إرسال الحجز إلى مسار الاعتماد." });
    expect(rpc).toHaveBeenCalledWith("request_booking_approval", expect.objectContaining({ p_organization_id: "organization", p_booking_id: "booking", p_idempotency_key: "request-key" }));
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
    expect(mocks.reportFailure).toHaveBeenCalledWith(expect.stringContaining("workspace.booking.confirm_booking"), expect.any(Object), expect.anything());
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
      .resolves.toEqual({ status: "success", message: "تم اعتماد الحجز." });
    await expect(decideBookingApprovalAction({ status: "idle", message: "" }, formData({ approval_request_id: "approval", decision: "approved", reason: "مراجعة" })))
      .resolves.toEqual({ status: "denied", message: "لا تملك صلاحية اتخاذ هذا القرار." });
    await expect(decideBookingApprovalAction({ status: "idle", message: "" }, formData({ approval_request_id: "approval", decision: "approved", reason: "مراجعة" })))
      .resolves.toEqual({ status: "retry", message: "تعذر حفظ قرار الاعتماد الآن." });
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/approvals");
    expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.approval.booking.decide", expect.any(Object), expect.any(String));
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
    expect(rpc).toHaveBeenCalledWith("record_booking_stay_event", expect.objectContaining({ p_event_type: eventType, p_notes: "notes", p_organization_id: "organization" }));
    vi.clearAllMocks();
  });
});
