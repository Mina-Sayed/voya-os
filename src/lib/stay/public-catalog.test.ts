import { afterEach, describe, expect, it, vi } from "vitest";

const mock = vi.hoisted(() => ({ serviceClient: vi.fn(), reportOperationalError: vi.fn() }));
vi.mock("@/lib/supabase/server-auth", () => ({ createServiceRoleSupabaseClient: mock.serviceClient }));
vi.mock("@/lib/observability/operational-error", () => ({ reportOperationalError: mock.reportOperationalError }));

import { getVoyaStayRequestConfig, getVoyaStayPublicListing, listVoyaStayPublicListings } from "./public-catalog";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
  delete process.env.VOYA_STAY_REQUEST_HMAC_SECRET;
});

describe("VOYA Stay public catalog adapter", () => {
  it("uses tenant-free read RPCs and resolves only approved derivative paths", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: [{
      slug: "stay-a101",
      title: "إقامة المعادي",
      description: "وصف عام معتمد",
      area_label: "المعادي",
      bedrooms: 2,
      max_guests: 4,
      amenities: ["wifi"],
      image_paths: ["aaaaaaaa-0000-0000-0000-000000000811.webp"],
      advisory_available: null,
    }], error: null });
    const getPublicUrl = vi.fn().mockReturnValue({ data: { publicUrl: "https://storage.example.test/public/stay.webp" } });
    mock.serviceClient.mockReturnValue({ rpc, storage: { from: vi.fn().mockReturnValue({ getPublicUrl }) } });

    const result = await listVoyaStayPublicListings({ destination: "المعادي", checkIn: "2027-01-01", checkOut: "2027-01-03", guests: 2, bedrooms: null });

    expect(rpc).toHaveBeenCalledWith("list_voya_stay_public_listings_v1", {
      p_destination: "المعادي", p_check_in: "2027-01-01", p_check_out: "2027-01-03", p_guests: 2, p_bedrooms: null,
    });
    expect(rpc.mock.calls[0]?.[1]).not.toHaveProperty("p_organization_id");
    expect(result).toEqual([expect.objectContaining({
      slug: "stay-a101", title: "إقامة المعادي", areaLabel: "المعادي",
      images: [{ url: "https://storage.example.test/public/stay.webp", alt: "إقامة المعادي" }],
      advisoryAvailable: null,
    })]);
    expect(getPublicUrl).toHaveBeenCalledWith("aaaaaaaa-0000-0000-0000-000000000811.webp");
  });

  it("fails closed to an empty public catalog if configuration or RPC reads fail", async () => {
    mock.serviceClient.mockReturnValue({ rpc: vi.fn().mockResolvedValue({ data: null, error: { code: "XX000" } }) });
    await expect(listVoyaStayPublicListings({ destination: null, checkIn: null, checkOut: null, guests: null, bedrooms: null })).resolves.toEqual([]);
    await expect(getVoyaStayPublicListing("stay-a101")).resolves.toBeNull();
    expect(mock.reportOperationalError).toHaveBeenCalledWith(expect.objectContaining({
      code: "stay_public_catalog_failed",
      outcome: "unavailable",
    }));
  });

  it("treats absent local Supabase service configuration as a quiet disabled state", async () => {
    mock.serviceClient.mockImplementation(() => { throw new SupabaseConfigurationError(); });
    await expect(listVoyaStayPublicListings({ destination: null, checkIn: null, checkOut: null, guests: null, bedrooms: null })).resolves.toEqual([]);
    await expect(getVoyaStayRequestConfig()).resolves.toEqual({ requestsEnabled: false, privacyNoticeUrl: null, privacyNoticeVersion: null });
    expect(mock.reportOperationalError).not.toHaveBeenCalled();
  });

  it("returns only the current privacy notice configuration for the request form", async () => {
    process.env.VOYA_STAY_REQUEST_HMAC_SECRET = "test-only-secret-with-more-than-32-characters";
    const rpc = vi.fn().mockResolvedValue({ data: [{ requests_enabled: true, privacy_notice_url: "https://voya.example/privacy", privacy_notice_version: "2026-09-v1" }], error: null });
    mock.serviceClient.mockReturnValue({ rpc });
    await expect(getVoyaStayRequestConfig()).resolves.toEqual({
      requestsEnabled: true,
      privacyNoticeUrl: "https://voya.example/privacy",
      privacyNoticeVersion: "2026-09-v1",
    });
    expect(rpc).toHaveBeenCalledWith("get_voya_stay_public_request_config_v1");
  });

  it("keeps request controls disabled when the HMAC rate-limit secret is absent", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: [{ requests_enabled: true, privacy_notice_url: "https://voya.example/privacy", privacy_notice_version: "2026-09-v1" }], error: null });
    mock.serviceClient.mockReturnValue({ rpc });
    await expect(getVoyaStayRequestConfig()).resolves.toEqual({
      requestsEnabled: false,
      privacyNoticeUrl: "https://voya.example/privacy",
      privacyNoticeVersion: "2026-09-v1",
    });
  });

  it("keeps production request controls disabled until edge rate limiting is asserted", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VOYA_STAY_REQUEST_HMAC_SECRET", "test-only-secret-with-more-than-32-characters");
    vi.stubEnv("VOYA_STAY_EDGE_RATE_LIMIT_ENABLED", "");
    const rpc = vi.fn().mockResolvedValue({ data: [{ requests_enabled: true, privacy_notice_url: "https://voya.example/privacy", privacy_notice_version: "2026-09-v1" }], error: null });
    mock.serviceClient.mockReturnValue({ rpc });
    await expect(getVoyaStayRequestConfig()).resolves.toMatchObject({ requestsEnabled: false });
  });
});
