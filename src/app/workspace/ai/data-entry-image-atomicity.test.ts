import { afterEach, describe, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  createServerClient: vi.fn(),
  createServiceClient: vi.fn(),
  revalidatePath: vi.fn(),
  reportFailure: vi.fn(),
}));

vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: mocks.createServerClient,
  createServiceRoleSupabaseClient: mocks.createServiceClient,
}));
vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));

import { confirmAiDataEntryDraftAction, type DataEntryActionState } from "./data-entry-actions";

const initialState: DataEntryActionState = { status: "idle", message: "" };
const organizationId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
const draftId = "aaaaaaaa-0000-4000-8000-000000000001";
const inputId = "aaaaaaaa-0000-4000-8000-000000000002";
const propertyId = "aaaaaaaa-0000-4000-8000-000000000003";
const imageId = "aaaaaaaa-0000-4000-8000-000000000004";
const executionToken = "aaaaaaaa-0000-4000-8000-000000000005";

afterEach(() => vi.clearAllMocks());

function confirmationForm(): FormData {
  const form = new FormData();
  form.set("draft_id", draftId);
  form.set("expected_version", "2");
  form.set("confirmation_idempotency_key", "atomic-image-confirmation");
  form.set("included_property_indexes", "[0]");
  form.set("payload_json", JSON.stringify({
    clients: [],
    properties: [{
      code: "ATOMIC-IMAGE",
      name: "Atomic image property",
      timezone: "Africa/Cairo",
      address: null,
      city: null,
      unitLabel: null,
      bedrooms: null,
      maxGuests: null,
      operationalNotes: null,
      imageInputIds: [inputId],
      confidence: "high",
      missingRequired: [],
    }],
    unresolved: [],
    warnings: [],
  }));
  return form;
}

describe("AI image confirmation atomicity", () => {
  test("does not call the legacy mapping RPC after atomic image registration", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });

    const userRpc = vi.fn().mockImplementation(async (name: string) => {
      if (name === "get_ai_data_entry_draft_v1") {
        return { data: [{ id: draftId, status: "ready_for_review", version: 2, expires_at: "2099-01-01T00:00:00.000Z", application_result: { clients: [], properties: [], images: [] } }], error: null };
      }
      if (name === "list_ai_data_entry_inputs_v1") {
        return { data: [{ id: inputId, storage_bucket: "ai-intake", storage_path: `${organizationId}/${draftId}/${inputId}.png`, mime_type: "image/png", byte_size: 3, status: "active", mapped_property_id: null }], error: null };
      }
      if (name === "claim_ai_data_entry_confirmation_v3") {
        return { data: [{ outcome: "claimed", execution_token: executionToken, draft_version: 3, application_result: { clients: [], properties: [], images: [] } }], error: null };
      }
      if (name === "create_property_v1") return { data: propertyId, error: null };
      return { data: null, error: null };
    });
    mocks.createServerClient.mockResolvedValue({ rpc: userRpc });

    const serviceRpc = vi.fn().mockImplementation(async (name: string) => {
      if (name === "apply_ai_data_entry_property_image_v1") return { data: imageId, error: null };
      if (name === "mark_ai_data_entry_input_mapped_v2") return { data: false, error: { code: "simulated_mapping_failure" } };
      return { data: true, error: null };
    });
    const source = { arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer };
    const storageFrom = vi.fn().mockImplementation((bucket: string) => {
      if (bucket === "ai-intake") return {
        download: vi.fn().mockResolvedValue({ data: source, error: null }),
        remove: vi.fn().mockResolvedValue({ data: [], error: null }),
      };
      return {
        upload: vi.fn().mockResolvedValue({ data: { path: "copied" }, error: null }),
        remove: vi.fn().mockResolvedValue({ data: [], error: null }),
      };
    });
    mocks.createServiceClient.mockReturnValue({ rpc: serviceRpc, storage: { from: storageFrom } });

    const result = await confirmAiDataEntryDraftAction(initialState, confirmationForm());

    expect(result).toEqual({ status: "success", message: "تم حفظ البيانات المؤكدة.", clientIds: [], propertyIds: [propertyId] });
    expect(serviceRpc).not.toHaveBeenCalledWith("mark_ai_data_entry_input_mapped_v2", expect.anything());
    expect(serviceRpc).toHaveBeenCalledWith("apply_ai_data_entry_property_image_v1", expect.objectContaining({
      p_draft_id: draftId,
      p_input_id: inputId,
      p_property_id: propertyId,
      p_execution_token: executionToken,
      p_idempotency_key: `ai-data-entry:${draftId}:property:0:image:${inputId}`,
    }));
    expect(userRpc).not.toHaveBeenCalledWith("register_property_image_v1", expect.anything());
  });
});
