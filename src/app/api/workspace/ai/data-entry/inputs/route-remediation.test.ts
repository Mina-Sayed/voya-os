import { NextRequest } from "next/server";
import { afterEach, describe, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  createServerClient: vi.fn(),
  createServiceClient: vi.fn(),
}));

vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: vi.fn(),
}));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: mocks.createServerClient,
  createServiceRoleSupabaseClient: mocks.createServiceClient,
}));

import { POST } from "./route";

const organizationId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
const draftId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
const inputId = "cccccccc-cccc-cccc-cccc-cccccccccccc";

function request() {
  return new NextRequest(`https://voya.test/api/workspace/ai/data-entry/inputs?draft_id=${draftId}`, {
    method: "POST",
    headers: {
      "content-type": "image/png",
      "content-length": "3",
      "x-idempotency-key": "same-upload-key",
    },
    body: new Blob([new Uint8Array([1, 2, 3])], { type: "image/png" }),
  });
}

afterEach(() => vi.clearAllMocks());

describe("AI intake upload remediation", () => {
  test("reuses the same storage path for the same idempotency key", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    const paths: string[] = [];
    const upload = vi.fn().mockImplementation(async (path: string) => {
      paths.push(path);
      return { error: null };
    });
    const remove = vi.fn().mockResolvedValue({ error: null });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ upload, remove }) } });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: inputId, error: null }) });

    expect((await POST(request())).status).toBe(201);
    expect((await POST(request())).status).toBe(201);

    expect(paths).toHaveLength(2);
    expect(paths[0]).toBe(paths[1]);
  });

  test("rejects an idempotency-key replay when the existing object has different bytes", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    const upload = vi.fn().mockResolvedValue({ error: { message: "already exists" } });
    const download = vi.fn().mockResolvedValue({
      data: new Blob([new Uint8Array([9, 9, 9])], { type: "image/png" }),
      error: null,
    });
    const remove = vi.fn().mockResolvedValue({ error: null });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ upload, download, remove }) } });
    const rpc = vi.fn();
    mocks.createServerClient.mockResolvedValue({ rpc });

    const response = await POST(request());

    expect(response.status).toBe(400);
    expect(download).toHaveBeenCalledTimes(1);
    expect(rpc).not.toHaveBeenCalled();
    expect(remove).not.toHaveBeenCalled();
  });
});
