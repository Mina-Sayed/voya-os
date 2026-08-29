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

  it("signs only a stored tenant-authorized media row", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: [{ message_id: "message", storage_bucket: "ai-intake", storage_path: "organization/conversation/message.jpg", mime_type: "image/jpeg" }], error: null }) });
    const createSignedUrl = vi.fn().mockResolvedValue({ data: { signedUrl: "https://storage.test/signed/media?token=short" }, error: null });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ createSignedUrl }) } });

    const response = await GET(new NextRequest("https://voya.test/api/workspace/whatsapp/media/message"), context);
    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe("https://storage.test/signed/media?token=short");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(createSignedUrl).toHaveBeenCalledWith("organization/conversation/message.jpg", 300);
  });

  it("does not sign absent or non-intake media", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: [{ message_id: "message", storage_bucket: "property-images", storage_path: "organization/property/file.jpg" }], error: null }) });
    const response = await GET(new NextRequest("https://voya.test/api/workspace/whatsapp/media/message"), context);
    expect(response.status).toBe(404);
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });
});
