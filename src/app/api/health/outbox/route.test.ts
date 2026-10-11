import { NextRequest } from "next/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createServiceClient: vi.fn() }));

vi.mock("@/lib/supabase/server-auth", () => ({
  createServiceRoleSupabaseClient: mocks.createServiceClient,
}));

// The gauge caches per module isolate; reload it per test so each case
// measures a fresh compute, and freeze time so ages are deterministic.
let GET: typeof import("./route").GET;

beforeEach(async () => {
  vi.resetModules();
  ({ GET } = await import("./route"));
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-01-01T00:00:00.000Z"));
});

afterEach(() => {
  vi.useRealTimers();
});

type Counts = Record<string, number>;

function fakeClient(counts: Counts, oldestCreatedAt: string | null, error: unknown = null) {
  const selected: Array<{ columns: string }> = [];
  const chain = {
    select: vi.fn((columns: string) => {
      selected.push({ columns });
      return chain;
    }),
    eq: vi.fn((_column: string, state: string) => ({ count: counts[state] ?? 0, error })),
    in: vi.fn(() => chain),
    order: vi.fn(() => chain),
    limit: vi.fn(() => chain),
    maybeSingle: vi.fn(() => ({
      data: oldestCreatedAt ? { created_at: oldestCreatedAt } : null,
      error,
    })),
  };
  return {
    client: { from: vi.fn((table: string) => ({ table, ...chain })) },
    selected,
  };
}

describe("outbox backlog gauge", () => {
  it("returns aggregate counts plus the oldest actionable age", async () => {
    const { client, selected } = fakeClient(
      { pending: 4, processing: 1, retry_wait: 2, completed: 90, dead_letter: 3 },
      new Date(Date.now() - 120_000).toISOString(),
    );
    mocks.createServiceClient.mockReturnValue(client);

    const response = await GET();
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.status).toBe("ok");
    expect(body.states).toEqual({ pending: 4, processing: 1, retry_wait: 2, completed: 90, dead_letter: 3 });
    expect(body.oldest_actionable_age_seconds).toBeGreaterThanOrEqual(119);
    expect(typeof body.checked_at).toBe("string");
    // Privacy: only aggregate identifiers leave the database.
    expect(selected.every(({ columns }) => columns === "id" || columns === "created_at")).toBe(true);
    const tables = (client.from.mock.calls as Array<[string]>).map(([table]) => table);
    expect(new Set(tables)).toEqual(new Set(["outbox_events"]));
  });

  it("returns empty backlog without an age", async () => {
    const { client } = fakeClient(
      { pending: 0, processing: 0, retry_wait: 0, completed: 5, dead_letter: 0 },
      null,
    );
    mocks.createServiceClient.mockReturnValue(client);

    const response = await GET();
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.oldest_actionable_age_seconds).toBeNull();
  });

  it("fails closed when the database is unreachable", async () => {
    const { client } = fakeClient({}, null, { code: "XX000" });
    mocks.createServiceClient.mockReturnValue(client);

    const response = await GET();
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ status: "unavailable" });
  });

  it("is reachable without authentication and carries no-store headers", async () => {
    const { client } = fakeClient(
      { pending: 0, processing: 0, retry_wait: 0, completed: 0, dead_letter: 0 },
      null,
    );
    mocks.createServiceClient.mockReturnValue(client);

    // The gauge takes no request input and performs no auth check by design
    // (aggregate counts only); this pins that contract.
    const response = await GET();
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
  });

  it("serves repeated hits from the origin cache without new database rounds", async () => {
    const { client } = fakeClient(
      { pending: 4, processing: 1, retry_wait: 2, completed: 90, dead_letter: 3 },
      new Date(Date.now() - 120_000).toISOString(),
    );
    mocks.createServiceClient.mockReturnValue(client);

    const first = await GET();
    const second = await GET();
    expect((await second.json()).checked_at).toBe((await first.json()).checked_at);
    expect(client.from.mock.calls.length).toBe(6);
  });

  it("logs gauge failures with the request id and keeps the body generic", async () => {
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const { client } = fakeClient({}, null, { code: "XX000" });
      mocks.createServiceClient.mockReturnValue(client);

      const request = new NextRequest("https://voya.test/api/health/outbox", {
        headers: { "x-request-id": "gauge-case-3" },
      });
      const response = await GET(request);
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ status: "unavailable" });
      const logged = write.mock.calls.map((args) => String(args[0]));
      expect(logged.some((line) => line.includes('"request_id":"gauge-case-3"'))).toBe(true);
    } finally {
      write.mockRestore();
    }
  });
});
