import { randomUUID } from "node:crypto";
import { reportOperationalError } from "@/lib/observability/operational-error";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServiceRoleSupabaseClient } from "@/lib/supabase/server-auth";

export type StaySearchCriteria = Readonly<{
  destination: string | null;
  checkIn: string | null;
  checkOut: string | null;
  guests: number | null;
  bedrooms: number | null;
}>;

export type VoyaStayPublicListing = Readonly<{
  slug: string;
  title: string;
  description: string;
  areaLabel: string;
  bedrooms: number;
  maxGuests: number;
  amenities: readonly string[];
  images: readonly Readonly<{ url: string; alt: string }>[];
  advisoryAvailable: boolean | null;
}>;

export type VoyaStayRequestConfig = Readonly<{
  requestsEnabled: boolean;
  privacyNoticeUrl: string | null;
  privacyNoticeVersion: string | null;
}>;

type PublicListingRow = Readonly<{
  slug: string;
  title: string;
  description: string;
  area_label: string;
  bedrooms: number;
  max_guests: number;
  amenities: string[] | null;
  image_paths: string[] | null;
  advisory_available: boolean | null;
}>;

type PublicImageStorage = Readonly<{
  getPublicUrl: (path: string) => { data: { publicUrl: string } };
}>;

const publicMediaBucket = "voya-stay-public-media";
const mediaPathPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]webp$/iu;
const slugPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/u;

function reportPublicCatalogFailure(operation: string, cause: unknown): void {
  if (cause instanceof SupabaseConfigurationError) return;
  reportOperationalError({
    operation,
    requestId: randomUUID(),
    code: "stay_public_catalog_failed",
    outcome: "unavailable",
    cause,
  });
}

function uncachedFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  return fetch(input, { ...init, cache: "no-store" });
}

function mapPublicListing(row: PublicListingRow, imageStorage: PublicImageStorage): VoyaStayPublicListing | null {
  if (!slugPattern.test(row.slug) || !row.title || !row.description || !row.area_label) return null;
  const images = (row.image_paths ?? [])
    .filter((path) => mediaPathPattern.test(path))
    .map((path) => {
      const url = imageStorage.getPublicUrl(path).data.publicUrl;
      if (!url) return null;
      try {
        const parsed = new URL(url);
        if (!["https:", "http:"].includes(parsed.protocol)) return null;
      } catch {
        return null;
      }
      return { url, alt: row.title };
    })
    .filter((image): image is Readonly<{ url: string; alt: string }> => image !== null);

  return {
    slug: row.slug,
    title: row.title,
    description: row.description,
    areaLabel: row.area_label,
    bedrooms: row.bedrooms,
    maxGuests: row.max_guests,
    amenities: (row.amenities ?? []).filter((amenity) => typeof amenity === "string"),
    images,
    advisoryAvailable: row.advisory_available,
  };
}

function asRows(value: unknown): readonly PublicListingRow[] {
  return Array.isArray(value) ? value as PublicListingRow[] : [];
}

export async function listVoyaStayPublicListings(criteria: StaySearchCriteria): Promise<readonly VoyaStayPublicListing[]> {
  try {
    const client = createServiceRoleSupabaseClient({ fetch: uncachedFetch });
    const { data, error } = await client.rpc("list_voya_stay_public_listings_v1", {
      p_destination: criteria.destination,
      p_check_in: criteria.checkIn,
      p_check_out: criteria.checkOut,
      p_guests: criteria.guests,
      p_bedrooms: criteria.bedrooms,
    });
    if (error) {
      reportPublicCatalogFailure("voya_stay.public_catalog.list", error);
      return [];
    }
    const imageStorage = client.storage.from(publicMediaBucket);
    return asRows(data)
      .map((row) => mapPublicListing(row, imageStorage))
      .filter((listing): listing is VoyaStayPublicListing => listing !== null);
  } catch (cause) {
    reportPublicCatalogFailure("voya_stay.public_catalog.list", cause);
    return [];
  }
}

export async function getVoyaStayPublicListing(
  slug: string,
  checkIn: string | null = null,
  checkOut: string | null = null,
): Promise<VoyaStayPublicListing | null> {
  if (!slugPattern.test(slug) || slug.length > 80) return null;
  try {
    const client = createServiceRoleSupabaseClient({ fetch: uncachedFetch });
    const { data, error } = await client.rpc("get_voya_stay_public_listing_v1", {
      p_slug: slug,
      p_check_in: checkIn,
      p_check_out: checkOut,
    });
    if (error) {
      reportPublicCatalogFailure("voya_stay.public_catalog.get", error);
      return null;
    }
    const row = asRows(data)[0];
    return row ? mapPublicListing(row, client.storage.from(publicMediaBucket)) : null;
  } catch (cause) {
    reportPublicCatalogFailure("voya_stay.public_catalog.get", cause);
    return null;
  }
}

const disabledRequestConfig: VoyaStayRequestConfig = {
  requestsEnabled: false,
  privacyNoticeUrl: null,
  privacyNoticeVersion: null,
};

export async function getVoyaStayRequestConfig(): Promise<VoyaStayRequestConfig> {
  try {
    const client = createServiceRoleSupabaseClient({ fetch: uncachedFetch });
    const { data, error } = await client.rpc("get_voya_stay_public_request_config_v1");
    if (error) {
      reportPublicCatalogFailure("voya_stay.request_config.read", error);
      return disabledRequestConfig;
    }
    const value = Array.isArray(data) ? data[0] : data;
    if (!value || typeof value !== "object") return disabledRequestConfig;
    const config = value as { requests_enabled?: unknown; privacy_notice_url?: unknown; privacy_notice_version?: unknown };
    let noticeUrl: string | null = null;
    if (typeof config.privacy_notice_url === "string") {
      const parsed = new URL(config.privacy_notice_url);
      if (parsed.protocol === "https:") noticeUrl = parsed.toString();
    }
    const version = typeof config.privacy_notice_version === "string"
      && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/u.test(config.privacy_notice_version)
      ? config.privacy_notice_version
      : null;
    const requestSecret = process.env.VOYA_STAY_REQUEST_HMAC_SECRET?.trim();
    const rateLimitConfigured = Boolean(requestSecret && Buffer.byteLength(requestSecret, "utf8") >= 32);
    const edgeRateLimitConfigured = process.env.NODE_ENV !== "production"
      || process.env.VOYA_STAY_EDGE_RATE_LIMIT_ENABLED === "1";
    const requestsEnabled = config.requests_enabled === true
      && noticeUrl !== null
      && version !== null
      && rateLimitConfigured
      && edgeRateLimitConfigured;
    return { requestsEnabled, privacyNoticeUrl: noticeUrl, privacyNoticeVersion: version };
  } catch (cause) {
    reportPublicCatalogFailure("voya_stay.request_config.read", cause);
    return disabledRequestConfig;
  }
}
