import { NextRequest } from "next/server";
import { afterEach, describe, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  reportFailure: vi.fn(),
  createServerClient: vi.fn(),
  createServiceClient: vi.fn(),
}));

vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: mocks.createServerClient,
  createServiceRoleSupabaseClient: mocks.createServiceClient,
}));

import { POST } from "./route";

afterEach(() => vi.clearAllMocks());

const organizationId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
const draftId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
const inputId = "cccccccc-cccc-cccc-cccc-cccccccccccc";
const PNG_BYTES = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function imageRequest(body: Uint8Array = PNG_BYTES, headers: Record<string, string> = {}) {
  return new NextRequest(`https://voya.test/api/workspace/ai/data-entry/inputs?draft_id=${draftId}`, {
    method: "POST",
    headers: {
      "content-type": "image/png",
      "content-length": String(body.byteLength),
      "x-idempotency-key": "input-idempotency-1",
      ...headers,
    },
    body: Buffer.from(body),
  });
}

function serviceRowLookup(result: Readonly<{ data: { id: string; status?: string } | null; error: unknown | null }>) {
  const query: { eq: ReturnType<typeof vi.fn>; maybeSingle: ReturnType<typeof vi.fn> } = {
    eq: vi.fn(),
    maybeSingle: vi.fn().mockResolvedValue(result),
  };
  query.eq.mockReturnValue(query);
  return { select: vi.fn().mockReturnValue(query) };
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

  test("rejects forged PNG content before storage access", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });

    const response = await POST(imageRequest(new Uint8Array([1, 2, 3, 4])));

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

  test("treats a null registration result from an expired draft as invalid input", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    const upload = vi.fn().mockResolvedValue({ error: null });
    const remove = vi.fn().mockResolvedValue({ error: null });
    mocks.createServiceClient.mockReturnValue({
      storage: { from: vi.fn().mockReturnValue({ upload, remove }) },
      from: vi.fn().mockReturnValue(serviceRowLookup({ data: null, error: null })),
    });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: null, error: null }) });

    const response = await POST(imageRequest());
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body).toEqual({ error: "invalid_input" });
    expect(remove).toHaveBeenCalled();
  });

  test("removes the private object when metadata registration fails and no peer registered it", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    const upload = vi.fn().mockResolvedValue({ error: null });
    const remove = vi.fn().mockResolvedValue({ error: null });
    const storageFrom = vi.fn().mockReturnValue({ upload, remove });
    mocks.createServiceClient.mockReturnValue({
      storage: { from: storageFrom },
      from: vi.fn().mockReturnValue(serviceRowLookup({ data: null, error: null })),
    });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: null, error: { code: "23503" } }) });

    const response = await POST(imageRequest());

    expect(response.status).toBe(400);
    expect(remove).toHaveBeenCalledWith([expect.stringMatching(new RegExp(`^${organizationId}/${draftId}/[0-9a-f-]{36}\\.png$`))]);
  });

  test("does not let a replay register while the original uploader has not committed metadata", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    const upload = vi.fn().mockResolvedValue({ error: { message: "already exists" } });
    const download = vi.fn().mockResolvedValue({
      data: new Blob([PNG_BYTES], { type: "image/png" }),
      error: null,
    });
    const remove = vi.fn().mockResolvedValue({ error: null });
    mocks.createServiceClient.mockReturnValue({
      storage: { from: vi.fn().mockReturnValue({ upload, download, remove }) },
      from: vi.fn().mockReturnValue(serviceRowLookup({ data: null, error: null })),
    });
    const rpc = vi.fn().mockResolvedValue({ data: inputId, error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    const response = await POST(imageRequest());

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "registration_pending" });
    expect(rpc).not.toHaveBeenCalled();
    expect(remove).not.toHaveBeenCalled();
  });

  test("does not delete a stable upload if a concurrent retry registered the same active object", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    const upload = vi.fn().mockResolvedValue({ error: null });
    const remove = vi.fn().mockResolvedValue({ error: null });
    mocks.createServiceClient.mockReturnValue({
      storage: { from: vi.fn().mockReturnValue({ upload, remove }) },
      from: vi.fn().mockReturnValue(serviceRowLookup({ data: { id: inputId, status: "active" }, error: null })),
    });
    mocks.createServerClient.mockResolvedValue({
      rpc: vi.fn().mockResolvedValue({ data: null, error: { code: "57014" } }),
    });

    const response = await POST(imageRequest());

    expect(response.status).toBe(503);
    expect(remove).not.toHaveBeenCalled();
  });

  test("deletes a recreated stable upload when only archived peer metadata remains", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId, role: "operations" });
    const upload = vi.fn().mockResolvedValue({ error: null });
    const remove = vi.fn().mockResolvedValue({ error: null });
    mocks.createServiceClient.mockReturnValue({
      storage: { from: vi.fn().mockReturnValue({ upload, remove }) },
      from: vi.fn().mockReturnValue(serviceRowLookup({ data: { id: inputId, status: "archived" }, error: null })),
    });
    mocks.createServerClient.mockResolvedValue({
      rpc: vi.fn().mockResolvedValue({ data: null, error: { code: "40001" } }),
    });

    const response = await POST(imageRequest());

    expect(response.status).toBe(400);
    expect(remove).toHaveBeenCalledWith([expect.stringMatching(new RegExp(`^${organizationId}/${draftId}/[0-9a-f-]{36}\\.png$`))]);
  });
});