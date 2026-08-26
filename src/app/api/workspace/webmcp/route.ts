import { randomUUID } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { z } from "zod";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const MAX_BODY_BYTES = 24 * 1024;
const MAX_POSTGRES_BIGINT = BigInt("9223372036854775807");
const bookingDraftRoles = new Set(["owner", "manager", "sales_agent", "operations"]);

function isRealIsoDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const timestamp = Date.UTC(year, month - 1, day);
  return new Date(timestamp).toISOString().slice(0, 10) === value;
}

const isoDate = z.string().refine(isRealIsoDate, "invalid date");
const uuid = z.string().uuid();
const limit = z.number().int().min(1).max(50).default(20);
const amountMinor = z.string().regex(/^[0-9]{1,19}$/u);
const currency = z.string().regex(/^[A-Z]{3}$/u);

const requestSchema = z.discriminatedUnion("tool", [
  z.object({
    tool: z.literal("search_properties"),
    args: z.object({
      query: z.string().trim().max(160).optional(),
      city: z.string().trim().max(120).optional(),
      bedrooms: z.number().int().min(0).max(100).optional(),
      minGuests: z.number().int().min(1).max(1000).optional(),
      limit: limit.optional(),
    }).strict(),
  }).strict(),
  z.object({
    tool: z.literal("search_clients"),
    args: z.object({
      query: z.string().trim().min(1).max(160),
      limit: limit.optional(),
    }).strict(),
  }).strict(),
  z.object({
    tool: z.literal("check_property_availability"),
    args: z.object({ propertyId: uuid, checkIn: isoDate, checkOut: isoDate }).strict(),
  }).strict(),
  z.object({
    tool: z.literal("calculate_booking_quote"),
    args: z.object({ checkIn: isoDate, checkOut: isoDate, nightlyRateMinor: amountMinor, currency }).strict(),
  }).strict(),
  z.object({
    tool: z.literal("create_booking_draft"),
    args: z.object({
      propertyId: uuid,
      clientId: uuid,
      checkIn: isoDate,
      checkOut: isoDate,
      amountMinor,
      currency,
      idempotencyKey: z.string().trim().min(1).max(160),
    }).strict(),
  }).strict(),
]);

type PropertyRecord = Readonly<{
  id: string;
  code: string;
  name: string;
  address: string | null;
  city: string | null;
  unit_label: string | null;
  bedrooms: number | null;
  max_guests: number | null;
  status: string;
  current_property_owner_name: string | null;
}>;

type ClientRecord = Readonly<{
  id: string;
  display_name: string;
  phone: string | null;
  whatsapp: string | null;
  email: string | null;
  archived_at: string | null;
}>;

type AvailabilityBlockRecord = Readonly<{
  id: string;
  property_id: string;
  start_date: string;
  end_date: string;
  block_type: string;
  reason: string | null;
}>;

type BookingRecord = Readonly<{
  id: string;
  property_code: string;
  status: string;
  check_in: string;
  check_out: string;
}>;

function json(body: Readonly<Record<string, unknown>>, status = 200) {
  return NextResponse.json(body, {
    status,
    headers: {
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

function dateRangesOverlap(startA: string, endA: string, startB: string, endB: string): boolean {
  return startA < endB && endA > startB;
}

function numberOfNights(checkIn: string, checkOut: string): number {
  const start = Date.parse(`${checkIn}T00:00:00.000Z`);
  const end = Date.parse(`${checkOut}T00:00:00.000Z`);
  return Math.round((end - start) / 86_400_000);
}

function isSameOrigin(request: NextRequest): boolean {
  const origin = request.headers.get("origin");
  return origin !== null && origin === request.nextUrl.origin;
}

async function readJsonBody(request: NextRequest): Promise<unknown | null> {
  const declaredLength = request.headers.get("content-length");
  if (declaredLength) {
    const parsedLength = Number(declaredLength);
    if (!Number.isSafeInteger(parsedLength) || parsedLength < 0 || parsedLength > MAX_BODY_BYTES) return null;
  }
  if (!request.body) return null;

  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let totalBytes = 0;
  let text = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_BODY_BYTES) {
        await reader.cancel();
        return null;
      }
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
  } catch {
    return null;
  } finally {
    reader.releaseLock();
  }

  if (!text) return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return null;
  }
}

function textMatches(value: string | null, query: string): boolean {
  return (value ?? "").toLowerCase().includes(query);
}

export async function POST(request: NextRequest) {
  const requestId = randomUUID();
  if (!isSameOrigin(request)) return json({ error: "invalid_origin" }, 403);
  if (request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase() !== "application/json") {
    return json({ error: "unsupported_media_type" }, 415);
  }

  const rawBody = await readJsonBody(request);
  if (rawBody === null) return json({ error: "invalid_payload" }, 400);
  const parsed = requestSchema.safeParse(rawBody);
  if (!parsed.success) return json({ error: "invalid_input" }, 400);

  let membership;
  try {
    membership = await loadActionWorkspaceMembership();
  } catch (error) {
    reportWorkspaceActionFailure("workspace.webmcp.auth", error, requestId);
    return json({ error: "service_unavailable" }, 503);
  }
  if (!membership) return json({ error: "unauthorized" }, 401);

  const { tool, args } = parsed.data;
  if ("checkIn" in args && "checkOut" in args && args.checkIn >= args.checkOut) {
    return json({ error: "invalid_date_range" }, 400);
  }

  try {
    const client = await createServerSupabaseClient();

    if (tool === "search_properties") {
      const { data, error } = await client.rpc("list_properties_v1", { p_organization_id: membership.organizationId });
      if (error) {
        if (error.code === "42501") return json({ error: "forbidden" }, 403);
        reportWorkspaceActionFailure("workspace.webmcp.search_properties", error, requestId);
        return json({ error: "read_failed" }, 503);
      }
      const normalizedQuery = args.query?.toLowerCase() ?? "";
      const normalizedCity = args.city?.toLowerCase() ?? "";
      const records = ((data ?? []) as PropertyRecord[])
        .filter((property) => property.status === "active")
        .filter((property) => !normalizedQuery || [property.code, property.name, property.address, property.city, property.unit_label, property.current_property_owner_name].some((value) => textMatches(value, normalizedQuery)))
        .filter((property) => !normalizedCity || textMatches(property.city, normalizedCity) || textMatches(property.address, normalizedCity))
        .filter((property) => args.bedrooms === undefined || property.bedrooms === args.bedrooms)
        .filter((property) => args.minGuests === undefined || (property.max_guests ?? 0) >= args.minGuests)
        .slice(0, args.limit ?? 20)
        .map((property) => ({
          id: property.id,
          code: property.code,
          name: property.name,
          address: property.address,
          city: property.city,
          unitLabel: property.unit_label,
          bedrooms: property.bedrooms,
          maxGuests: property.max_guests,
          currentPropertyOwnerName: property.current_property_owner_name,
        }));
      return json({ properties: records, count: records.length });
    }

    if (tool === "search_clients") {
      const { data, error } = await client.rpc("list_clients_v1", { p_organization_id: membership.organizationId });
      if (error) {
        if (error.code === "42501") return json({ error: "forbidden" }, 403);
        reportWorkspaceActionFailure("workspace.webmcp.search_clients", error, requestId);
        return json({ error: "read_failed" }, 503);
      }
      const normalizedQuery = args.query.toLowerCase();
      const records = ((data ?? []) as ClientRecord[])
        .filter((record) => record.archived_at === null)
        .filter((record) => [record.display_name, record.phone, record.whatsapp, record.email].some((value) => textMatches(value, normalizedQuery)))
        .slice(0, args.limit ?? 20)
        .map((record) => ({ id: record.id, displayName: record.display_name, phone: record.phone, whatsapp: record.whatsapp, email: record.email }));
      return json({ clients: records, count: records.length });
    }

    if (tool === "check_property_availability") {
      const [propertiesResult, blocksResult, bookingsResult] = await Promise.all([
        client.rpc("list_properties_v1", { p_organization_id: membership.organizationId }),
        client.rpc("list_availability_blocks", { p_organization_id: membership.organizationId }),
        client.rpc("list_commercial_booking_work_queue", { p_organization_id: membership.organizationId }),
      ]);
      const firstError = propertiesResult.error ?? blocksResult.error ?? bookingsResult.error;
      if (firstError) {
        if (firstError.code === "42501") return json({ error: "forbidden" }, 403);
        reportWorkspaceActionFailure("workspace.webmcp.check_availability", firstError, requestId);
        return json({ error: "read_failed" }, 503);
      }

      const property = ((propertiesResult.data ?? []) as PropertyRecord[]).find((record) => record.id === args.propertyId && record.status === "active");
      if (!property) return json({ error: "property_not_found" }, 404);

      const blockingAvailability = ((blocksResult.data ?? []) as AvailabilityBlockRecord[])
        .filter((block) => block.property_id === property.id && dateRangesOverlap(args.checkIn, args.checkOut, block.start_date, block.end_date))
        .map((block) => ({ id: block.id, startDate: block.start_date, endDate: block.end_date, blockType: block.block_type, reason: block.reason }));
      const blockingBookings = ((bookingsResult.data ?? []) as BookingRecord[])
        .filter((booking) => booking.property_code === property.code && ["confirmed", "checked_in"].includes(booking.status) && dateRangesOverlap(args.checkIn, args.checkOut, booking.check_in, booking.check_out))
        .map((booking) => ({ id: booking.id, status: booking.status, checkIn: booking.check_in, checkOut: booking.check_out }));

      return json({
        property: { id: property.id, code: property.code, name: property.name },
        checkIn: args.checkIn,
        checkOut: args.checkOut,
        available: blockingAvailability.length === 0 && blockingBookings.length === 0,
        conflicts: { availabilityBlocks: blockingAvailability, confirmedBookings: blockingBookings },
      });
    }

    if (tool === "calculate_booking_quote") {
      const nights = numberOfNights(args.checkIn, args.checkOut);
      if (!Number.isSafeInteger(nights) || nights < 1 || nights > 3660) return json({ error: "invalid_date_range" }, 400);
      const nightlyRateMinor = BigInt(args.nightlyRateMinor);
      const totalMinor = nightlyRateMinor * BigInt(nights);
      if (totalMinor > MAX_POSTGRES_BIGINT) return json({ error: "amount_out_of_range" }, 400);
      return json({ checkIn: args.checkIn, checkOut: args.checkOut, nights, nightlyRateMinor: args.nightlyRateMinor, totalMinor: totalMinor.toString(), currency: args.currency });
    }

    if (!bookingDraftRoles.has(membership.role)) return json({ error: "forbidden" }, 403);
    const { data, error } = await client.rpc("create_commercial_booking_draft", {
      p_organization_id: membership.organizationId,
      p_property_id: args.propertyId,
      p_client_id: args.clientId,
      p_check_in: args.checkIn,
      p_check_out: args.checkOut,
      p_amount_minor: args.amountMinor,
      p_currency: args.currency,
      p_idempotency_key: args.idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      if (error.code === "42501") return json({ error: "forbidden" }, 403);
      if (["22003", "22023", "23503", "23505", "23514"].includes(error.code ?? "")) return json({ error: "invalid_input" }, 400);
      reportWorkspaceActionFailure("workspace.webmcp.create_booking_draft", error, requestId);
      return json({ error: "write_failed" }, 503);
    }
    if (typeof data !== "string") {
      reportWorkspaceActionFailure("workspace.webmcp.create_booking_draft", new Error("booking draft id missing"), requestId);
      return json({ error: "write_failed" }, 503);
    }
    return json({ bookingId: data, status: "draft" }, 201);
  } catch (error) {
    reportWorkspaceActionFailure(`workspace.webmcp.${tool}`, error, requestId);
    if (error instanceof SupabaseConfigurationError) return json({ error: "not_configured" }, 503);
    return json({ error: "service_unavailable" }, 503);
  }
}
