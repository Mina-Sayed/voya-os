import { NextRequest } from "next/server";
import { afterEach, describe, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  createServerClient: vi.fn(),
  createServiceClient: vi.fn(),
}));

vi.mock("@/features/auth/workspace-context", () => ({ loadActionWorkspaceMembership: mocks.loadMembership }));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: mocks.createServerClient,
  createServiceRoleSupabaseClient: mocks.createServiceClient,
}));

import { POST } from "./route";

afterEach(() => vi.clearAllMocks());

const organizationId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
const draftId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
const inputId = "cccccccc-cccc-cccc-cccc-cccccccccccc";

function imageRequest(body: Uint8Array = new Uint8Array([1, 2, 3]), headers: Record<string, string> = {}) {
  return new NextRequest(`https://voya.test/api/workspace/ai/data-entry/inputs?draft_id=${draftId}`, {
    method: "POST",
    headers: {
      "content-type": "image/png",
      "content-length": String(body.byteLength),
      "x-idempotency-key": "input-idempotency-1",
      ...headers,
    },
    body: new Blob([body as unknown as ArrayBuffer], { type: headers["content-type"] ?? "image/png" }),
  });
}

describe("AI data-entry private input route", () => {
  test("fails closed without an active workspace membership", async () => {
    mocks.loadMembership.mockResolvedValue(null);

    const response = await POST(imageRequest());

    expect(response.status).toBe(401);
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });

  test("rejects unsupported files before storage access", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });

    const response = await POST(imageRequest(new Uint8Array([1]), { "content-type": "application/pdf" }));

    expect(response.status).toBe(400);
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });

  test("rejects oversized body from the bounded reader", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });

    const response = await POST(imageRequest(new Uint8Array([1]), { "content-length": String(10 * 1024 * 1024 + 1) }));

    expect(response.status).toBe(413);
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });

  test("uploads privately and registers only opaque input metadata", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    const upload = vi.fn().mockResolvedValue({ error: null });
    const remove = vi.fn().mockResolvedValue({ error: null });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ upload, remove }) } });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: inputId, error: null }) });

    const response = await POST(imageRequest());
    const body = await response.json();

    expect(response.status).toBe(201);
    expect(body).toEqual({ input_id: inputId });
    expect(upload).toHaveBeenCalledWith(expect.stringMatching(new RegExp(`^${organizationId}/${draftId}/[0-9a-f-]{36}\\.png$`)), expect.any(Uint8Array), expect.objectContaining({ contentType: "image/png", upsert: false }));
    expect(mocks.createServerClient.mock.results[0]?.value).toBeDefined();
    expect(remove).not.toHaveBeenCalled();
  });

  test("removes the private object when metadata registration fails", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    const upload = vi.fn().mockResolvedValue({ error: null });
    const remove = vi.fn().mockResolvedValue({ error: null });
    const from = vi.fn().mockReturnValue({ upload, remove });
    mocks.createServiceClient.mockReturnValue({ storage: { from } });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: null, error: { code: "23503" } }) });

    const response = await POST(imageRequest());

    expect(response.status).toBe(400);
    expect(remove).toHaveBeenCalledWith([expect.stringMatching(new RegExp(`^${organizationId}/${draftId}/[0-9a-f-]{36}\\.png$`))]);
  });
});
