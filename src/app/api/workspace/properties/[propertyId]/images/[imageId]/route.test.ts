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

const context = { params: Promise.resolve({ propertyId: "property", imageId: "image" }) };

describe("private property image route", () => {
  it("fails closed without an active workspace membership", async () => {
    mocks.loadMembership.mockResolvedValue(null);
    const response = await GET(new NextRequest("https://voya.test/api/workspace/properties/property/images/image"), context);
    expect(response.status).toBe(401);
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });

  it("returns only a short-lived signed redirect for a tenant-authorized image", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: [{ id: "image", storage_bucket: "property-images", storage_path: "organization/property/file.png" }], error: null }) });
    const createSignedUrl = vi.fn().mockResolvedValue({ data: { signedUrl: "https://storage.test/signed/file?token=short" }, error: null });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ createSignedUrl }) } });

    const response = await GET(new NextRequest("https://voya.test/api/workspace/properties/property/images/image"), context);
    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe("https://storage.test/signed/file?token=short");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(createSignedUrl).toHaveBeenCalledWith("organization/property/file.png", 300);
  });

  it("does not sign an image that is absent from the tenant-scoped RPC result", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: [], error: null }) });
    const response = await GET(new NextRequest("https://voya.test/api/workspace/properties/property/images/image"), context);
    expect(response.status).toBe(404);
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });
});
