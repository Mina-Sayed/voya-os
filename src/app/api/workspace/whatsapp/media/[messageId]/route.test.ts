import { NextRequest } from "next/server";
import { afterEach, describe, expect, it, vi } from "vitest";

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

import { GET } from "./route";

afterEach(() => vi.clearAllMocks());

const context = { params: Promise.resolve({ messageId: "message" }) };

describe("private WhatsApp media route", () => {
  it("fails closed without a workspace membership", async () => {
    mocks.loadMembership.mockResolvedValue(null);
    const response = await GET(new NextRequest("https://voya.test/api/workspace/whatsapp/media/message"), context);
    expect(response.status).toBe(401);
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });

  it("streams tenant-authorized image bytes from the same origin", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: [{ message_id: "message", storage_bucket: "ai-intake", storage_path: "organization/conversation/message.jpg", mime_type: "image/jpeg" }], error: null }) });
    const download = vi.fn().mockResolvedValue({ data: new Blob([new Uint8Array([0xff, 0xd8, 0xff, 0xd9])], { type: "image/jpeg" }), error: null });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ download }) } });

    const response = await GET(new NextRequest("https://voya.test/api/workspace/whatsapp/media/message"), context);
    expect(response.status).toBe(200);
    expect(response.headers.get("location")).toBeNull();
    expect(response.headers.get("content-type")).toBe("image/jpeg");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(Array.from(new Uint8Array(await response.arrayBuffer()))).toEqual([0xff, 0xd8, 0xff, 0xd9]);
    expect(download).toHaveBeenCalledWith("organization/conversation/message.jpg");
  });

  it("does not sign absent or non-intake media", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: [{ message_id: "message", storage_bucket: "property-images", storage_path: "organization/property/file.jpg" }], error: null }) });
    const response = await GET(new NextRequest("https://voya.test/api/workspace/whatsapp/media/message"), context);
    expect(response.status).toBe(404);
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });

  it("returns a generic 503 when the media lookup fails", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: null, error: { message: "relation does not exist" } }) });
    const response = await GET(new NextRequest("https://voya.test/api/workspace/whatsapp/media/message"), context);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "media_unavailable" });
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });

  it("returns a generic 503 when the storage download fails", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: [{ message_id: "message", storage_bucket: "ai-intake", storage_path: "organization/conversation/message.jpg", mime_type: "image/jpeg" }], error: null }) });
    const download = vi.fn().mockResolvedValue({ data: null, error: { message: "object not found" } });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ download }) } });
    const response = await GET(new NextRequest("https://voya.test/api/workspace/whatsapp/media/message"), context);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "media_unavailable" });
  });

  it("returns a generic 503 for oversize media without reading the bytes", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: [{ message_id: "message", storage_bucket: "ai-intake", storage_path: "organization/conversation/message.jpg", mime_type: "image/jpeg" }], error: null }) });
    const arrayBuffer = vi.fn();
    const download = vi.fn().mockResolvedValue({ data: { size: 10 * 1024 * 1024 + 1, arrayBuffer }, error: null });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ download }) } });
    const response = await GET(new NextRequest("https://voya.test/api/workspace/whatsapp/media/message"), context);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "media_unavailable" });
    expect(arrayBuffer).not.toHaveBeenCalled();
  });

  it("returns a generic 503 when the bytes fail the image signature check", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: [{ message_id: "message", storage_bucket: "ai-intake", storage_path: "organization/conversation/message.jpg", mime_type: "image/jpeg" }], error: null }) });
    const download = vi.fn().mockResolvedValue({ data: new Blob([new Uint8Array([0x00, 0x01, 0x02, 0x03])], { type: "image/jpeg" }), error: null });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ download }) } });
    const response = await GET(new NextRequest("https://voya.test/api/workspace/whatsapp/media/message"), context);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "media_unavailable" });
  });
});
