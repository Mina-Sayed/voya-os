import { NextRequest } from "next/server";
import { afterEach, describe, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  createServerClient: vi.fn(),
  createServiceClient: vi.fn(),
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

import { GET } from "./route";

afterEach(() => vi.clearAllMocks());

const organizationId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
const draftId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
const inputId = "cccccccc-cccc-cccc-cccc-cccccccccccc";
const storagePath = `${organizationId}/${draftId}/${inputId}.png`;

function previewRequest(id = inputId) {
  return new NextRequest(`https://voya.test/api/workspace/ai/data-entry/inputs/preview?draft_id=${draftId}&input_id=${id}`);
}

describe("AI data-entry intake preview route", () => {
  test("never reaches storage without an authorized membership", async () => {
    mocks.loadMembership.mockResolvedValue(null);

    const response = await GET(previewRequest());

    expect(response.status).toBe(401);
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });

  test("does not accept an arbitrary storage object that is absent from the authorized draft", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: [], error: null }) });

    const response = await GET(previewRequest());

    expect(response.status).toBe(404);
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });

  test("rejects a database row with an unapproved mime type before privileged storage access", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    mocks.createServerClient.mockResolvedValue({
      rpc: vi.fn().mockResolvedValue({
        data: [{ id: inputId, storage_bucket: "ai-intake", storage_path: storagePath, mime_type: "text/html", byte_size: 3, status: "active" }],
        error: null,
      }),
    });

    const response = await GET(previewRequest());

    expect(response.status).toBe(404);
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });

  test("does not reach privileged storage for a mapped input whose intake object was already cleaned", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    mocks.createServerClient.mockResolvedValue({
      rpc: vi.fn().mockResolvedValue({
        data: [{ id: inputId, storage_bucket: "ai-intake", storage_path: storagePath, mime_type: "image/png", byte_size: 3, status: "mapped" }],
        error: null,
      }),
    });

    const response = await GET(previewRequest());

    expect(response.status).toBe(404);
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });

  test("streams only the database-authorized private input with no-store headers", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    mocks.createServerClient.mockResolvedValue({
      rpc: vi.fn().mockResolvedValue({
        data: [{ id: inputId, storage_bucket: "ai-intake", storage_path: storagePath, mime_type: "image/png", byte_size: 3, status: "active" }],
        error: null,
      }),
    });
    const download = vi.fn().mockResolvedValue({ data: new Blob([new Uint8Array([1, 2, 3])], { type: "image/png" }), error: null });
    const from = vi.fn().mockReturnValue({ download });
    mocks.createServiceClient.mockReturnValue({ storage: { from } });

    const response = await GET(previewRequest());

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("image/png");
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(from).toHaveBeenCalledWith("ai-intake");
    expect(download).toHaveBeenCalledWith(storagePath);
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
  });
});
