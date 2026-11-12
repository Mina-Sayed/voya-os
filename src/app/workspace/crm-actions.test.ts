import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createServerClient: vi.fn(),
  loadMembership: vi.fn(),
  reportFailure: vi.fn(),
  revalidatePath: vi.fn(),
}));

vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createServerClient }));
vi.mock("@/lib/organizations/organization-timezone", () => ({ readOrganizationTimezone: vi.fn().mockResolvedValue("Africa/Cairo") }));

import { archiveClientAction, createClientAction, deleteClientAction, updateClientAction } from "./clients/actions";
import { archiveLeadAction, completeLeadFollowUpAction, convertLeadToClientAction, createLeadAction, createLeadActivityAction, createLeadFollowUpAction, deleteLeadAction, updateLeadAction } from "./leads/actions";

function formData(values: Record<string, string>): FormData {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

const leadValues = {
  name: "أحمد CRM",
  phone: "+201000000701",
  whatsapp: "",
  email: "ahmed@example.test",
  source: "website",
  status: "new",
  requested_area: "المعادي",
  requested_check_in: "2027-02-01",
  requested_check_out: "2027-02-07",
  guests: "3",
  bedrooms: "2",
  budget_text: "50000 EGP",
  notes: "طلب عائلي",
  next_follow_up_at: "2027-01-20T10:00",
  idempotency_key: "crm-lead-key",
};

afterEach(() => vi.clearAllMocks());

describe("CRM V1 server actions", () => {
  it("creates a lead through the V1 RPC with normalized command fields", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(createLeadAction({ status: "idle", message: "" }, formData(leadValues))).resolves.toEqual({ status: "success", message: "تمت إضافة طلب CRM." });
    expect(rpc).toHaveBeenCalledWith("create_lead_v1", expect.objectContaining({ p_organization_id: "organization", p_name: "أحمد CRM", p_phone: "+201000000701", p_requested_area: "المعادي", p_guests: 3, p_next_follow_up_at: expect.stringMatching(/^2027-01-20T\d{2}:00:00\.000Z$/u) }));
  });

  it("keeps malformed V1 lead input before the provider boundary", async () => {
    await expect(createLeadAction({ status: "idle", message: "" }, formData({ name: "بدون وسيلة", source: "website", idempotency_key: "key" }))).resolves.toMatchObject({ status: "invalid" });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
    expect(mocks.createServerClient).not.toHaveBeenCalled();
  });

  it.each([
    ["updateLeadAction", updateLeadAction, "update_lead_v1", { ...leadValues, lead_id: "lead", expected_version: "1", idempotency_key: "lead-update-key" }],
    ["archiveLeadAction", archiveLeadAction, "archive_lead_v1", { lead_id: "lead", expected_version: "1", reason: "طلب قديم", idempotency_key: "lead-archive-key" }],
    ["createLeadActivityAction", createLeadActivityAction, "create_lead_activity_v1", { lead_id: "lead", activity_type: "call", content: "تم التواصل", idempotency_key: "activity-key" }],
    ["createLeadFollowUpAction", createLeadFollowUpAction, "create_lead_follow_up_v1", { lead_id: "lead", due_at: "2027-01-20T10:00", note: "إرسال الخيارات", idempotency_key: "follow-up-key" }],
    ["completeLeadFollowUpAction", completeLeadFollowUpAction, "complete_lead_follow_up_v1", { follow_up_id: "follow-up", completion_note: "تم التنفيذ", idempotency_key: "complete-key" }],
    ["convertLeadToClientAction", convertLeadToClientAction, "convert_lead_to_client_v1", { lead_id: "lead", idempotency_key: "convert-key" }],
  ] as const)("routes %s through %s", async (_name, action, rpcName, values) => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(action({ status: "idle", message: "" }, formData(values))).resolves.toMatchObject({ status: "success" });
    expect(rpc).toHaveBeenCalledWith(rpcName, expect.objectContaining({ p_organization_id: "organization", p_request_id: expect.any(String) }));
  });

  it("creates, updates, and archives clients through V1 RPCs", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(createClientAction({ status: "idle", message: "" }, formData({ display_name: "عميل CRM", phone: "+201000000702", whatsapp: "", email: "client@example.test", nationality: "EG", preferred_language: "ar", notes: "ملاحظة", idempotency_key: "client-key" }))).resolves.toMatchObject({ status: "success" });
    await expect(updateClientAction({ status: "idle", message: "" }, formData({ client_id: "client", expected_version: "1", display_name: "عميل محدث", phone: "+201000000702", whatsapp: "", email: "client@example.test", nationality: "EG", preferred_language: "ar", notes: "محدث", idempotency_key: "client-update-key" }))).resolves.toMatchObject({ status: "success" });
    await expect(archiveClientAction({ status: "idle", message: "" }, formData({ client_id: "client", expected_version: "2", reason: "طلب المستخدم", idempotency_key: "client-archive-key" }))).resolves.toMatchObject({ status: "success" });
    expect(rpc.mock.calls.map(([name]) => name)).toEqual(["create_client_v1", "update_client_v1", "archive_client_v1"]);
  });

  it.each([
    ["lead update", updateLeadAction, { ...leadValues, lead_id: "lead", expected_version: "1", idempotency_key: "lead-update-errors" }, "update_lead_v1"],
    ["lead archive", archiveLeadAction, { lead_id: "lead", expected_version: "1", reason: "طلب قديم", idempotency_key: "lead-archive-errors" }, "archive_lead_v1"],
    ["lead activity", createLeadActivityAction, { lead_id: "lead", activity_type: "call", content: "تم التواصل", idempotency_key: "activity-errors" }, "create_lead_activity_v1"],
    ["lead follow-up", createLeadFollowUpAction, { lead_id: "lead", due_at: "2027-01-20T10:00", note: "إرسال الخيارات", idempotency_key: "follow-up-errors" }, "create_lead_follow_up_v1"],
    ["lead follow-up completion", completeLeadFollowUpAction, { follow_up_id: "follow-up", completion_note: "تم التنفيذ", idempotency_key: "complete-errors" }, "complete_lead_follow_up_v1"],
    ["lead conversion", convertLeadToClientAction, { lead_id: "lead", idempotency_key: "convert-errors" }, "convert_lead_to_client_v1"],
    ["client update", updateClientAction, { client_id: "client", expected_version: "1", display_name: "عميل محدث", phone: "+201000000702", email: "client@example.test", idempotency_key: "client-update-errors" }, "update_client_v1"],
    ["client archive", archiveClientAction, { client_id: "client", expected_version: "1", reason: "طلب المستخدم", idempotency_key: "client-archive-errors" }, "archive_client_v1"],
  ] as const)("maps expected database errors for %s", async (_name, action, values, rpcName) => {
    for (const [code, expectedStatus] of [["42501", "denied"], ["22023", "invalid"], ["XX000", "retry"]] as const) {
      vi.clearAllMocks();
      mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
      const rpcError = { code, message: "provider detail" };
      const rpc = vi.fn().mockResolvedValue({ error: rpcError });
      mocks.createServerClient.mockResolvedValue({ rpc });

      await expect(action({ status: "idle", message: "" }, formData(values))).resolves.toMatchObject({ status: expectedStatus });
      expect(rpc).toHaveBeenCalledWith(rpcName, expect.any(Object));
      if (expectedStatus === "retry") expect(mocks.reportFailure).toHaveBeenCalled();
      else expect(mocks.reportFailure).not.toHaveBeenCalled();
    }
  });

  it.each(["viewer", "accountant"] as const)("denies legacy %s creation for roles outside the command set", async (role) => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(createClientAction({ status: "idle", message: "" }, formData({ display_name: "عميل قديم", idempotency_key: "legacy-client-key" })))
      .resolves.toMatchObject({ status: "denied" });
    await expect(createLeadAction({ status: "idle", message: "" }, formData({ title: "طلب قديم", source: "website", idempotency_key: "legacy-lead-key" })))
      .resolves.toMatchObject({ status: "denied" });
    expect(rpc).not.toHaveBeenCalled();
  });
});


describe("CRM owner-only permanent delete actions", () => {
  const leadId = "aaaaaaaa-0000-0000-0000-000000000f01";
  const clientId = "aaaaaaaa-0000-0000-0000-000000000f02";

  it.each([
    ["lead", deleteLeadAction, "lead_id", leadId, "delete_crm_lead_v1"],
    ["client", deleteClientAction, "client_id", clientId, "delete_crm_client_v1"],
  ] as const)("deletes a %s through tenant-scoped RPC with name, version and request ID", async (_kind, action, field, id, rpcName) => {
    mocks.loadMembership.mockResolvedValue({ role: "owner", organizationId: "org-1" });
    const rpc = vi.fn().mockResolvedValue({ data: true, error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(action({ status: "idle", message: "" }, formData({
      [field]: id, confirm_name: "أحمد", expected_version: "2",
    }))).resolves.toMatchObject({ status: "success" });
    expect(rpc).toHaveBeenCalledWith(rpcName, expect.objectContaining({
      p_organization_id: "org-1",
      p_confirm_name: "أحمد",
      p_expected_version: 2,
      p_request_id: expect.any(String),
    }));
    expect(mocks.revalidatePath).toHaveBeenCalled();
  });

  it.each(["manager", "sales_agent", "operations", "viewer"] as const)(
    "denies permanent deletion for %s without touching Supabase", async (role) => {
      mocks.loadMembership.mockResolvedValue({ role, organizationId: "org-1" });
      await expect(deleteLeadAction({ status: "idle", message: "" }, formData({
        lead_id: leadId, confirm_name: "أحمد", expected_version: "1",
      }))).resolves.toMatchObject({ status: "denied" });
      await expect(deleteClientAction({ status: "idle", message: "" }, formData({
        client_id: clientId, confirm_name: "أحمد", expected_version: "1",
      }))).resolves.toMatchObject({ status: "denied" });
      expect(mocks.createServerClient).not.toHaveBeenCalled();
    },
  );

  it("rejects malformed ID, missing typed name and invalid version before any provider call", async () => {
    const invalidValues: Record<string, string>[] = [
      { lead_id: "not-a-uuid", confirm_name: "أحمد", expected_version: "1" },
      { lead_id: leadId, expected_version: "1" },
      { lead_id: leadId, confirm_name: "أحمد", expected_version: "0" },
    ];
    for (const values of invalidValues) {
      await expect(deleteLeadAction({ status: "idle", message: "" }, formData(values)))
        .resolves.toMatchObject({ status: "invalid" });
    }
    expect(mocks.loadMembership).not.toHaveBeenCalled();
    expect(mocks.createServerClient).not.toHaveBeenCalled();
  });

  it.each([
    ["23503", "invalid"],
    ["22023", "invalid"],
    ["40001", "invalid"],
    ["42501", "denied"],
    ["XX000", "retry"],
  ] as const)("maps deletion SQLSTATE %s to %s without exposing raw DB errors", async (code, status) => {
    mocks.loadMembership.mockResolvedValue({ role: "owner", organizationId: "org-1" });
    const rpc = vi.fn().mockResolvedValue({ error: { code, message: "internal DB details" } });
    mocks.createServerClient.mockResolvedValue({ rpc });
    const result = await deleteLeadAction({ status: "idle", message: "" }, formData({
      lead_id: leadId, confirm_name: "أحمد", expected_version: "1",
    }));
    expect(result.status).toBe(status);
    expect(result.message).not.toContain("internal DB details");
    if (status === "retry") expect(mocks.reportFailure).toHaveBeenCalled();
  });

  it("never declares deletion successful if provider fails to confirm", async () => {
    mocks.loadMembership.mockResolvedValue({ role: "owner", organizationId: "org-1" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: null, error: null }) });
    await expect(deleteClientAction({ status: "idle", message: "" }, formData({
      client_id: clientId, confirm_name: "أحمد", expected_version: "1",
    }))).resolves.toMatchObject({ status: "retry" });
    expect(mocks.revalidatePath).not.toHaveBeenCalled();
  });
});
