import { afterEach, describe, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  createClient: vi.fn(),
  createServiceClient: vi.fn(),
  revalidatePath: vi.fn(),
  reportFailure: vi.fn(),
}));

vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: mocks.createClient,
  createServiceRoleSupabaseClient: mocks.createServiceClient,
}));
vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));

import {
  confirmAiDataEntryDraftAction,
  createAiDataEntryDraftAction,
  submitAiDataEntryDraftAction,
  type DataEntryActionState,
} from "./data-entry-actions";

afterEach(() => vi.clearAllMocks());

const initialState: DataEntryActionState = { status: "idle", message: "" };
const membership = { organizationId: "organization", role: "operations" };

function formData(values: Record<string, string>) {
  const form = new FormData();
  for (const [key, value] of Object.entries(values)) form.set(key, value);
  return form;
}

describe("AI data-entry actions", () => {
  test("rejects an empty intake without an idempotency key", async () => {
    const result = await createAiDataEntryDraftAction(initialState, formData({ source_text: "", idempotency_key: "" }));

    expect(result).toEqual({ status: "invalid", message: "اكتب بيانات قبل بدء الاستخراج." });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
  });

  test("binds draft creation to the verified membership organization", async () => {
    mocks.loadMembership.mockResolvedValue(membership);
    const rpc = vi.fn().mockResolvedValue({ data: "draft-id", error: null });
    mocks.createClient.mockResolvedValue({ rpc });

    const result = await createAiDataEntryDraftAction(initialState, formData({ source_text: "أحمد، +201000000000", idempotency_key: "draft-key" }));

    expect(result).toEqual({ status: "success", message: "تم تجهيز المسودة لرفع الصور وإرسالها للاستخراج.", draftId: "draft-id" });
    expect(rpc).toHaveBeenCalledWith("create_ai_data_entry_draft_v1", expect.objectContaining({
      p_organization_id: "organization",
      p_source_text: "أحمد، +201000000000",
      p_idempotency_key: "draft-key",
    }));
  });

  test("denies roles outside the operational data-entry boundary", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "viewer" });

    const result = await createAiDataEntryDraftAction(initialState, formData({ source_text: "عميل", idempotency_key: "draft-key" }));

    expect(result).toEqual({ status: "denied", message: "لا تملك صلاحية تجهيز مسودة إدخال بيانات." });
    expect(mocks.createClient).not.toHaveBeenCalled();
  });

  test("submits only a verified draft id and stable idempotency key", async () => {
    mocks.loadMembership.mockResolvedValue(membership);
    const rpc = vi.fn().mockResolvedValue({ data: "run-id", error: null });
    mocks.createClient.mockResolvedValue({ rpc });

    const result = await submitAiDataEntryDraftAction(initialState, formData({ draft_id: "draft-id", idempotency_key: "submit-key" }));

    expect(result).toEqual({ status: "success", message: "تم إرسال المسودة للاستخراج والمراجعة.", runId: "run-id" });
    expect(rpc).toHaveBeenCalledWith("submit_ai_data_entry_draft_v1", expect.objectContaining({ p_draft_id: "draft-id", p_organization_id: "organization", p_idempotency_key: "submit-key" }));
  });

  test("requires complete editable fields before confirmation", async () => {
    mocks.loadMembership.mockResolvedValue(membership);
    const rpc = vi.fn().mockImplementation(async (name: string) => {
      if (name === "get_ai_data_entry_draft_v1") return { data: [{ id: "draft-id", status: "ready_for_review", version: 2, expires_at: "2099-01-01T00:00:00.000Z", application_result: {} }], error: null };
      if (name === "list_ai_data_entry_inputs_v1") return { data: [], error: null };
      return { data: null, error: null };
    });
    mocks.createClient.mockResolvedValue({ rpc });

    const result = await confirmAiDataEntryDraftAction(initialState, formData({
      draft_id: "draft-id",
      expected_version: "2",
      confirmation_idempotency_key: "confirm-key",
      payload_json: JSON.stringify({ clients: [{ displayName: null, phone: null, whatsapp: null, email: null, nationality: null, preferredLanguage: null, notes: null, sourceLeadId: null, confidence: "low", missingRequired: ["display_name"] }], properties: [], unresolved: [], warnings: [] }),
    }));

    expect(result).toEqual({ status: "invalid", message: "أكمل الحقول المطلوبة قبل تأكيد الحفظ." });
    expect(rpc).not.toHaveBeenCalledWith("claim_ai_data_entry_confirmation_v2", expect.anything());
  });

  test("confirms a client draft through a serialized human claim and trusted finalizer", async () => {
    mocks.loadMembership.mockResolvedValue(membership);
    const rpc = vi.fn().mockImplementation(async (name: string) => {
      if (name === "get_ai_data_entry_draft_v1") {
        return { data: [{ id: "draft-id", status: "ready_for_review", version: 2, expires_at: "2099-01-01T00:00:00.000Z", application_result: { clients: [], properties: [], images: [] } }], error: null };
      }
      if (name === "list_ai_data_entry_inputs_v1") return { data: [], error: null };
      if (name === "claim_ai_data_entry_confirmation_v2") {
        return { data: [{ outcome: "claimed", execution_token: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", draft_version: 3, application_result: { clients: [], properties: [], images: [] } }], error: null };
      }
      if (name === "create_client_v1") return { data: "client-id", error: null };
      return { data: null, error: null };
    });
    const serviceRpc = vi.fn().mockResolvedValue({ data: true, error: null });
    mocks.createClient.mockResolvedValue({ rpc });
    mocks.createServiceClient.mockReturnValue({ rpc: serviceRpc, storage: { from: vi.fn() } });

    const result = await confirmAiDataEntryDraftAction(initialState, formData({
      draft_id: "draft-id",
      expected_version: "2",
      confirmation_idempotency_key: "confirm-key",
      included_client_indexes: "[0]",
      included_property_indexes: "[]",
      payload_json: JSON.stringify({ clients: [{ displayName: "أحمد", phone: "+201000000000", whatsapp: null, email: null, nationality: "مصري", preferredLanguage: "ar", notes: null, sourceLeadId: null, confidence: "high", missingRequired: [] }], properties: [], unresolved: [], warnings: [] }),
    }));

    expect(result).toEqual({ status: "success", message: "تم حفظ البيانات المؤكدة.", clientIds: ["client-id"], propertyIds: [] });
    expect(rpc).toHaveBeenCalledWith("claim_ai_data_entry_confirmation_v2", expect.objectContaining({
      p_organization_id: "organization",
      p_draft_id: "draft-id",
      p_expected_version: 2,
      p_idempotency_key: "confirm-key",
    }));
    expect(rpc).toHaveBeenCalledWith("create_client_v1", expect.objectContaining({ p_display_name: "أحمد", p_phone: "+201000000000", p_idempotency_key: "ai-data-entry:draft-id:client:0" }));
    expect(serviceRpc).toHaveBeenCalledWith("finalize_ai_data_entry_confirmation_v2", expect.objectContaining({
      p_draft_id: "draft-id",
      p_execution_token: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      p_status: "applied",
      p_expected_version: 3,
    }));
  });
});