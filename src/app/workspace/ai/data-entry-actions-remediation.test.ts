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

import { createAiDataEntryDraftAction, type DataEntryActionState } from "./data-entry-actions";

const initialState: DataEntryActionState = { status: "idle", message: "" };

afterEach(() => vi.clearAllMocks());

describe("AI data-entry action remediation", () => {
  test("allows creating an image-only draft with empty source text", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    const rpc = vi.fn().mockResolvedValue({ data: "draft-id", error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });
    const form = new FormData();
    form.set("source_text", "");
    form.set("idempotency_key", "image-only-draft-key");

    const result = await createAiDataEntryDraftAction(initialState, form);

    expect(result).toMatchObject({ status: "success", draftId: "draft-id" });
    expect(rpc).toHaveBeenCalledWith("create_ai_data_entry_draft_v1", expect.objectContaining({
      p_organization_id: "organization",
      p_source_text: "",
      p_idempotency_key: "image-only-draft-key",
    }));
  });
});
