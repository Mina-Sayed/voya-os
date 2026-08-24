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

import { confirmAiDataEntryDraftAction, type DataEntryActionState } from "./data-entry-actions";

const initialState: DataEntryActionState = { status: "idle", message: "" };

function formData(values: Record<string, string>) {
  const form = new FormData();
  for (const [key, value] of Object.entries(values)) form.set(key, value);
  return form;
}

afterEach(() => vi.clearAllMocks());

describe("AI data-entry confirmation recovery contract", () => {
  test("persists exclusions in v3 claim and durable success before continuing", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });

    const rpc = vi.fn().mockImplementation(async (name: string) => {
      if (name === "get_ai_data_entry_draft_v1") {
        return {
          data: [{
            id: "draft-id",
            status: "ready_for_review",
            version: 2,
            expires_at: "2099-01-01T00:00:00.000Z",
            application_result: { clients: [], properties: [], images: [] },
          }],
          error: null,
        };
      }
      if (name === "list_ai_data_entry_inputs_v1") return { data: [], error: null };
      if (name === "claim_ai_data_entry_confirmation_v3") {
        return {
          data: [{
            outcome: "claimed",
            execution_token: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            draft_version: 3,
            application_result: {
              clients: [{ index: 0, errorCode: "excluded_by_operator" }],
              properties: [],
              images: [],
            },
          }],
          error: null,
        };
      }
      if (name === "create_client_v1") return { data: "client-id", error: null };
      return { data: null, error: null };
    });

    const serviceRpc = vi.fn().mockImplementation(async (name: string) => {
      if (name === "heartbeat_ai_data_entry_confirmation_v3") return { data: true, error: null };
      if (name === "persist_ai_data_entry_confirmation_progress_v1") return { data: true, error: null };
      if (name === "finalize_ai_data_entry_confirmation_v2") return { data: true, error: null };
      return { data: null, error: null };
    });

    mocks.createClient.mockResolvedValue({ rpc });
    mocks.createServiceClient.mockReturnValue({ rpc: serviceRpc, storage: { from: vi.fn() } });

    const payload = {
      clients: [
        { displayName: "لا تحفظني", phone: null, whatsapp: null, email: null, nationality: null, preferredLanguage: "ar", notes: null, sourceLeadId: null, confidence: "high", missingRequired: [] },
        { displayName: "احفظني", phone: null, whatsapp: null, email: null, nationality: null, preferredLanguage: "ar", notes: null, sourceLeadId: null, confidence: "high", missingRequired: [] },
      ],
      properties: [],
      unresolved: [],
      warnings: [],
    };

    const result = await confirmAiDataEntryDraftAction(initialState, formData({
      draft_id: "draft-id",
      expected_version: "2",
      confirmation_idempotency_key: "confirm-key",
      included_client_indexes: "[1]",
      included_property_indexes: "[]",
      payload_json: JSON.stringify(payload),
    }));

    expect(result).toEqual({
      status: "success",
      message: "تم حفظ البيانات المؤكدة.",
      clientIds: ["client-id"],
      propertyIds: [],
    });

    expect(rpc).toHaveBeenCalledWith("claim_ai_data_entry_confirmation_v3", expect.objectContaining({
      p_organization_id: "organization",
      p_draft_id: "draft-id",
      p_excluded_client_indexes: [0],
      p_excluded_property_indexes: [],
      p_expected_version: 2,
      p_idempotency_key: "confirm-key",
    }));
    expect(rpc).not.toHaveBeenCalledWith("claim_ai_data_entry_confirmation_v2", expect.anything());
    expect(rpc).toHaveBeenCalledWith("create_client_v1", expect.objectContaining({ p_display_name: "احفظني" }));
    expect(rpc).not.toHaveBeenCalledWith("create_client_v1", expect.objectContaining({ p_display_name: "لا تحفظني" }));

    expect(serviceRpc).toHaveBeenCalledWith("heartbeat_ai_data_entry_confirmation_v3", {
      p_organization_id: "organization",
      p_draft_id: "draft-id",
      p_execution_token: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    });
    expect(serviceRpc).toHaveBeenCalledWith("persist_ai_data_entry_confirmation_progress_v1", expect.objectContaining({
      p_organization_id: "organization",
      p_draft_id: "draft-id",
      p_execution_token: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      p_application_result: expect.objectContaining({
        clients: expect.arrayContaining([
          { index: 0, errorCode: "excluded_by_operator" },
          { index: 1, recordId: "client-id" },
        ]),
      }),
    }));

    const heartbeatCall = serviceRpc.mock.calls.findIndex(([name]) => name === "heartbeat_ai_data_entry_confirmation_v3");
    const createClientCall = rpc.mock.calls.findIndex(([name]) => name === "create_client_v1");
    const persistCall = serviceRpc.mock.calls.findIndex(([name]) => name === "persist_ai_data_entry_confirmation_progress_v1");
    const finalizerCall = serviceRpc.mock.calls.findIndex(([name]) => name === "finalize_ai_data_entry_confirmation_v2");
    expect(heartbeatCall).toBeGreaterThanOrEqual(0);
    expect(createClientCall).toBeGreaterThanOrEqual(0);
    expect(persistCall).toBeGreaterThanOrEqual(0);
    expect(finalizerCall).toBeGreaterThanOrEqual(0);
    expect(serviceRpc.mock.invocationCallOrder[heartbeatCall]).toBeLessThan(rpc.mock.invocationCallOrder[createClientCall]);
    expect(rpc.mock.invocationCallOrder[createClientCall]).toBeLessThan(serviceRpc.mock.invocationCallOrder[persistCall]);
    expect(serviceRpc.mock.invocationCallOrder[persistCall]).toBeLessThan(serviceRpc.mock.invocationCallOrder[finalizerCall]);
  });
});
