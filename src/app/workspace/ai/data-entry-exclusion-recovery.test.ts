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

describe("AI data-entry exclusion recovery", () => {
  test("persists operator exclusions when another item leaves the draft partially applied", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    const rpc = vi.fn().mockImplementation(async (name: string) => {
      if (name === "get_ai_data_entry_draft_v1") {
        return { data: [{ id: "draft-id", status: "ready_for_review", version: 2, expires_at: "2099-01-01T00:00:00.000Z", application_result: { clients: [], properties: [], images: [] } }], error: null };
      }
      if (name === "list_ai_data_entry_inputs_v1") return { data: [], error: null };
      if (name === "claim_ai_data_entry_confirmation_v2") {
        return { data: [{ outcome: "claimed", execution_token: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", draft_version: 3, application_result: { clients: [], properties: [], images: [] } }], error: null };
      }
      if (name === "create_client_v1") return { data: null, error: { code: "23505" } };
      return { data: null, error: null };
    });
    const serviceRpc = vi.fn().mockResolvedValue({ data: true, error: null });
    mocks.createClient.mockResolvedValue({ rpc });
    mocks.createServiceClient.mockReturnValue({ rpc: serviceRpc, storage: { from: vi.fn() } });

    const payload = {
      clients: [
        { displayName: "لا تحفظني", phone: null, whatsapp: null, email: null, nationality: null, preferredLanguage: "ar", notes: null, sourceLeadId: null, confidence: "high", missingRequired: [] },
        { displayName: "حاول حفظي", phone: null, whatsapp: null, email: null, nationality: null, preferredLanguage: "ar", notes: null, sourceLeadId: null, confidence: "high", missingRequired: [] },
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

    expect(result.status).toBe("retry");
    expect(serviceRpc).toHaveBeenCalledWith("finalize_ai_data_entry_confirmation_v2", expect.objectContaining({
      p_status: "partially_applied",
      p_application_result: {
        clients: [
          { index: 0, errorCode: "excluded_by_operator" },
          { index: 1, errorCode: "23505" },
        ],
        properties: [],
        images: [],
      },
    }));
  });
});
