import { NextRequest, NextResponse } from "next/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import { proxy } from "./proxy";
import { resolveRequestId } from "@/lib/observability/request-id";

vi.mock("@/lib/supabase/proxy-client", () => ({
  refreshSupabaseSession: vi.fn(
    async (
      _request: NextRequest,
      _a: unknown,
      _b: unknown,
      forwardedHeaders?: Headers,
    ) => {
      capturedForwarded = forwardedHeaders ?? null;
      return NextResponse.next();
    },
  ),
}));

let capturedForwarded: Headers | null = null;

function requestWith(id: string | null): NextRequest {
  const headers = new Headers();
  if (id !== null) headers.set("x-request-id", id);
  return new NextRequest("https://voya.test/workspace", { headers });
}

describe("resolveRequestId", () => {
  it("echoes a valid client-supplied token unchanged", () => {
    expect(resolveRequestId("order-123_abc")).toBe("order-123_abc");
  });

  it("generates a UUID-shaped id when absent", () => {
    expect(resolveRequestId(null)).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
  });

  it("generates instead of passing through oversized input", () => {
    const generated = resolveRequestId("x".repeat(129));
    expect(generated).not.toBe("x".repeat(129));
  });

  it("generates instead of passing through header-injection characters", () => {
    for (const hostile of ["a\nSet-Cookie: x=1", "a\rb", "with space", "semi;colon", "uni\u2028sep"]) {
      const generated = resolveRequestId(hostile);
      expect(generated).not.toContain(hostile);
      expect(generated).toMatch(/^[0-9a-f-]{36}$/);
    }
  });
});

describe("proxy request id", () => {
  it("forwards and echoes a valid incoming id", async () => {
    const response = await proxy(requestWith("support-ticket-42"));
    expect(response.headers.get("x-request-id")).toBe("support-ticket-42");
    expect(capturedForwarded?.get("x-request-id")).toBe("support-ticket-42");
  });

  it("generates, forwards, and echoes when the incoming id is hostile", async () => {
    const hostile = `way-too-long-${"x".repeat(130)}`;
    const response = await proxy(requestWith(hostile));
    const echoed = response.headers.get("x-request-id");
    expect(echoed).toMatch(/^[0-9a-f-]{36}$/);
    expect(capturedForwarded?.get("x-request-id")).toBe(echoed);
  });
});

describe("proxy canonical host", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  function productionRequest(host: string, path = "/sign-in", forwardedHost: string | null = host): NextRequest {
    const headers = new Headers();
    if (forwardedHost !== null) headers.set("x-forwarded-host", forwardedHost);
    return new NextRequest(`https://${host}${path}`, { headers });
  }

  function stubProductionEnvironment(): void {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VOYA_APP_URL", "https://www.vigor.dpdns.org");
    vi.stubEnv("VERCEL_PROJECT_PRODUCTION_URL", "voya-os.vercel.app");
  }

  it("redirects the retired alias to the canonical origin", async () => {
    stubProductionEnvironment();
    const response = await proxy(productionRequest("voya-os.vercel.app"));
    expect(response.status).toBe(308);
    expect(response.headers.get("location")).toBe("https://www.vigor.dpdns.org/sign-in");
  });

  it("never lets a redirect be cached", async () => {
    stubProductionEnvironment();
    const response = await proxy(productionRequest("voya-os.vercel.app"));
    expect(response.headers.get("cache-control")).toBe("private, no-store");
  });

  it("falls back to the request host when the forwarded host header is blank", async () => {
    stubProductionEnvironment();
    const response = await proxy(productionRequest("voya-os.vercel.app", "/sign-in", "   "));
    expect(response.status).toBe(308);
  });

  it("keeps serving the canonical host", async () => {
    stubProductionEnvironment();
    const response = await proxy(productionRequest("www.vigor.dpdns.org"));
    expect(response.status).toBe(200);
  });

  it("keeps API traffic reachable on any host", async () => {
    stubProductionEnvironment();
    const response = await proxy(productionRequest("voya-os.vercel.app", "/api/health"));
    expect(response.status).toBe(200);
  });

  it("does not redirect outside production", async () => {
    vi.stubEnv("VOYA_APP_URL", "https://www.vigor.dpdns.org");
    const response = await proxy(productionRequest("voya-os.vercel.app"));
    expect(response.status).toBe(200);
  });
});
