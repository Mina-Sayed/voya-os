import { beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  reportFailure: vi.fn(),
  createClient: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));

vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: mocks.createClient,
}));

vi.mock("@/lib/supabase/public-config", () => ({
  SupabaseConfigurationError: class SupabaseConfigurationError extends Error {},
}));

import { POST } from "./route";

function request(body: unknown, origin = "https://voya.test") {
  return new NextRequest("https://voya.test/api/workspace/webmcp", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin,
    },
    body: JSON.stringify(body),
  });
}

function oversizedStreamingRequest(origin = "https://voya.test") {
  let chunksRemaining = 4;
  const cancelled = vi.fn();
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      controller.enqueue(new Uint8Array(10 * 1024));
      chunksRemaining -= 1;
      if (chunksRemaining === 0) controller.close();
    },
    cancel: cancelled,
  });
  type NextRequestInit = NonNullable<ConstructorParameters<typeof NextRequest>[1]> & { duplex: "half" };
  const init: NextRequestInit = {
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin,
    },
    body: stream,
    duplex: "half",
  };
  return {
    request: new NextRequest("https://voya.test/api/workspace/webmcp", init),
    cancelled,
  };
}

async function jsonBody(response: Response) {
  return response.json() as Promise<Record<string, unknown>>;
}

describe("POST /api/workspace/webmcp", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({
      organizationId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      role: "manager",
    });
    mocks.createClient.mockResolvedValue({ rpc: mocks.rpc });
  });

  it("rejects cross-origin tool calls before reading workspace data", async () => {
    const response = await POST(request({ tool: "search_properties", args: {} }, "https://attacker.example"));

    expect(response.status).toBe(403);
    await expect(jsonBody(response)).resolves.toMatchObject({ error: "invalid_origin" });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("cancels an oversized streaming body without Content-Length before auth", async () => {
    const streamed = oversizedStreamingRequest();
    expect(streamed.request.headers.get("content-length")).toBeNull();

    const response = await POST(streamed.request);

    expect(response.status).toBe(400);
    await expect(jsonBody(response)).resolves.toMatchObject({ error: "invalid_payload" });
    expect(streamed.cancelled).toHaveBeenCalledTimes(1);
    expect(mocks.loadMembership).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("calculates a deterministic quote without inventing stored pricing", async () => {
    const response = await POST(request({
      tool: "calculate_booking_quote",
      args: {
        checkIn: "2026-09-01",
        checkOut: "2026-09-05",
        nightlyRateMinor: "250000",
        currency: "EGP",
      },
    }));

    expect(response.status).toBe(200);
    await expect(jsonBody(response)).resolves.toMatchObject({
      nights: 4,
      nightlyRateMinor: "250000",
      totalMinor: "1000000",
      currency: "EGP",
    });
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("reports confirmed booking and manual-block conflicts for availability", async () => {
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === "list_properties_v1") {
        return { data: [{ id: "11111111-1111-4111-8111-111111111111", code: "PROP-1", name: "Test Property", address: null, city: "Cairo", unit_label: null, bedrooms: 2, max_guests: 4, status: "active", current_property_owner_name: null }], error: null };
      }
      if (name === "list_availability_blocks") {
        return { data: [{ id: "block-1", property_id: "11111111-1111-4111-8111-111111111111", start_date: "2026-09-03", end_date: "2026-09-04", block_type: "maintenance", reason: "AC service" }], error: null };
      }
      if (name === "list_commercial_booking_work_queue") {
        return { data: [{ id: "booking-1", property_code: "PROP-1", status: "confirmed", check_in: "2026-09-04", check_out: "2026-09-07" }], error: null };
      }
      throw new Error(`unexpected rpc: ${name}`);
    });

    const response = await POST(request({
      tool: "check_property_availability",
      args: {
        propertyId: "11111111-1111-4111-8111-111111111111",
        checkIn: "2026-09-02",
        checkOut: "2026-09-06",
      },
    }));

    expect(response.status).toBe(200);
    const payload = await jsonBody(response);
    expect(payload.available).toBe(false);
    expect(payload.conflicts).toEqual({
      availabilityBlocks: [{ id: "block-1", startDate: "2026-09-03", endDate: "2026-09-04", blockType: "maintenance", reason: "AC service" }],
      confirmedBookings: [{ id: "booking-1", status: "confirmed", checkIn: "2026-09-04", checkOut: "2026-09-07" }],
    });
  });

  it("keeps booking creation draft-only and delegates authorization to the existing RPC", async () => {
    mocks.rpc.mockResolvedValue({ data: "22222222-2222-4222-8222-222222222222", error: null });

    const response = await POST(request({
      tool: "create_booking_draft",
      args: {
        propertyId: "11111111-1111-4111-8111-111111111111",
        clientId: "33333333-3333-4333-8333-333333333333",
        checkIn: "2026-09-01",
        checkOut: "2026-09-05",
        amountMinor: "1000000",
        currency: "EGP",
        idempotencyKey: "webmcp-test-1",
      },
    }));

    expect(response.status).toBe(201);
    await expect(jsonBody(response)).resolves.toMatchObject({ bookingId: "22222222-2222-4222-8222-222222222222", status: "draft" });
    expect(mocks.rpc).toHaveBeenCalledWith("create_commercial_booking_draft", expect.objectContaining({
      p_organization_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      p_property_id: "11111111-1111-4111-8111-111111111111",
      p_client_id: "33333333-3333-4333-8333-333333333333",
      p_check_in: "2026-09-01",
      p_check_out: "2026-09-05",
      p_amount_minor: "1000000",
      p_currency: "EGP",
      p_idempotency_key: "webmcp-test-1",
    }));
  });

  it("does not allow a viewer to create a booking draft", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", role: "viewer" });

    const response = await POST(request({
      tool: "create_booking_draft",
      args: {
        propertyId: "11111111-1111-4111-8111-111111111111",
        clientId: "33333333-3333-4333-8333-333333333333",
        checkIn: "2026-09-01",
        checkOut: "2026-09-05",
        amountMinor: "1000000",
        currency: "EGP",
        idempotencyKey: "webmcp-test-2",
      },
    }));

    expect(response.status).toBe(403);
    await expect(jsonBody(response)).resolves.toMatchObject({ error: "forbidden" });
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
