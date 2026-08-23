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
const organizationId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const draftId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const propertyId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const inputId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const token = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";

function formData(values: Record<string, string>) {
  const form = new FormData();
  for (const [key, value] of Object.entries(values)) form.set(key, value);
  return form;
}

function clientDraft(displayName = "عميل") {
  return { displayName, phone: null, whatsapp: null, email: null, nationality: null, preferredLanguage: "ar", notes: null, sourceLeadId: null, confidence: "high", missingRequired: [] };
}

function propertyDraft(imageInputIds: string[]) {
  return { code: "PROP-1", name: "عقار", timezone: "Africa/Cairo", address: null, city: null, unitLabel: null, bedrooms: null, maxGuests: null, operationalNotes: null, imageInputIds, confidence: "high", missingRequired: [] };
}

afterEach(() => vi.clearAllMocks());

describe("AI data-entry terminal cleanup recovery", () => {
  test("removes a copied property image when metadata registration definitively fails", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    const rpc = vi.fn().mockImplementation(async (name: string) => {
      if (name === "get_ai_data_entry_draft_v1") return { data: [{ id: draftId, status: "ready_for_review", version: 2, expires_at: "2099-01-01T00:00:00Z", application_result: { clients: [], properties: [], images: [] } }], error: null };
      if (name === "list_ai_data_entry_inputs_v1") return { data: [{ id: inputId, storage_bucket: "ai-intake", storage_path: `${organizationId}/${draftId}/${inputId}.png`, mime_type: "image/png", byte_size: 4, status: "active", mapped_property_id: null }], error: null };
      if (name === "claim_ai_data_entry_confirmation_v3") return { data: [{ outcome: "claimed", execution_token: token, draft_version: 3, application_result: { clients: [], properties: [], images: [] } }], error: null };
      if (name === "create_property_v1") return { data: propertyId, error: null };
      if (name === "register_property_image_v1") return { data: null, error: { code: "23514" } };
      return { data: null, error: null };
    });

    const propertyRemove = vi.fn().mockResolvedValue({ data: [], error: null });
    const intakeRemove = vi.fn().mockResolvedValue({ data: [], error: null });
    const serviceRpc = vi.fn().mockImplementation(async (name: string) => {
      if (name === "heartbeat_ai_data_entry_confirmation_v3") return { data: true, error: null };
      if (name === "finalize_ai_data_entry_confirmation_v2") return { data: true, error: null };
      return { data: true, error: null };
    });
    const storageFrom = vi.fn().mockImplementation((bucket: string) => {
      if (bucket === "ai-intake") return {
        download: vi.fn().mockResolvedValue({ data: new Blob([new Uint8Array([1, 2, 3, 4])]), error: null }),
        remove: intakeRemove,
      };
      if (bucket === "property-images") return {
        upload: vi.fn().mockResolvedValue({ data: { path: "copied" }, error: null }),
        remove: propertyRemove,
      };
      throw new Error(`unexpected bucket ${bucket}`);
    });
    mocks.createClient.mockResolvedValue({ rpc });
    mocks.createServiceClient.mockReturnValue({ rpc: serviceRpc, storage: { from: storageFrom } });

    const result = await confirmAiDataEntryDraftAction(initialState, formData({
      draft_id: draftId,
      expected_version: "2",
      confirmation_idempotency_key: "cleanup-register-failure",
      included_client_indexes: "[]",
      included_property_indexes: "[0]",
      payload_json: JSON.stringify({ clients: [], properties: [propertyDraft([inputId])], unresolved: [], warnings: [] }),
    }));

    const copiedPath = `${organizationId}/${propertyId}/${inputId}.png`;
    expect(result.status).toBe("retry");
    expect(propertyRemove).toHaveBeenCalledWith([copiedPath]);
    expect(serviceRpc).toHaveBeenCalledWith("finalize_ai_data_entry_confirmation_v2", expect.objectContaining({ p_status: "partially_applied" }));
  });

  test("archives and removes unassigned private inputs before allowing terminal applied", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    const intakePath = `${organizationId}/${draftId}/${inputId}.png`;
    const rpc = vi.fn().mockImplementation(async (name: string) => {
      if (name === "get_ai_data_entry_draft_v1") return { data: [{ id: draftId, status: "ready_for_review", version: 2, expires_at: "2099-01-01T00:00:00Z", application_result: { clients: [], properties: [], images: [] } }], error: null };
      if (name === "list_ai_data_entry_inputs_v1") return { data: [{ id: inputId, storage_bucket: "ai-intake", storage_path: intakePath, mime_type: "image/png", byte_size: 4, status: "active", mapped_property_id: null }], error: null };
      if (name === "claim_ai_data_entry_confirmation_v3") return { data: [{ outcome: "claimed", execution_token: token, draft_version: 3, application_result: { clients: [], properties: [], images: [] } }], error: null };
      if (name === "create_client_v1") return { data: "ffffffff-ffff-4fff-8fff-ffffffffffff", error: null };
      return { data: null, error: null };
    });

    const intakeRemove = vi.fn().mockResolvedValue({ data: [], error: null });
    const serviceRpc = vi.fn().mockImplementation(async (name: string) => {
      if (name === "heartbeat_ai_data_entry_confirmation_v3") return { data: true, error: null };
      if (name === "archive_ai_data_entry_inputs_v1") return { data: true, error: null };
      if (name === "finalize_ai_data_entry_confirmation_v2") return { data: true, error: null };
      return { data: null, error: null };
    });
    mocks.createClient.mockResolvedValue({ rpc });
    mocks.createServiceClient.mockReturnValue({
      rpc: serviceRpc,
      storage: { from: vi.fn().mockReturnValue({ remove: intakeRemove }) },
    });

    const result = await confirmAiDataEntryDraftAction(initialState, formData({
      draft_id: draftId,
      expected_version: "2",
      confirmation_idempotency_key: "cleanup-unassigned",
      included_client_indexes: "[0]",
      included_property_indexes: "[]",
      payload_json: JSON.stringify({ clients: [clientDraft()], properties: [], unresolved: [], warnings: [] }),
    }));

    expect(result.status).toBe("success");
    expect(serviceRpc).toHaveBeenCalledWith("archive_ai_data_entry_inputs_v1", {
      p_organization_id: organizationId,
      p_draft_id: draftId,
      p_input_ids: [inputId],
      p_execution_token: token,
    });
    expect(intakeRemove).toHaveBeenCalledWith([intakePath]);

    const archiveOrder = serviceRpc.mock.invocationCallOrder[serviceRpc.mock.calls.findIndex(([name]) => name === "archive_ai_data_entry_inputs_v1")];
    const finalizerOrder = serviceRpc.mock.invocationCallOrder[serviceRpc.mock.calls.findIndex(([name]) => name === "finalize_ai_data_entry_confirmation_v2")];
    expect(archiveOrder).toBeLessThan(finalizerOrder);
  });
});
