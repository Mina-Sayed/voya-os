import { afterEach, describe, expect, it, vi } from "vitest";

const mock = vi.hoisted(() => ({ createServiceClient: vi.fn(), reportFailure: vi.fn() }));
vi.mock("@/lib/supabase/server-auth", () => ({ createServiceRoleSupabaseClient: mock.createServiceClient }));
vi.mock("@/features/auth/workspace-context", () => ({ reportWorkspaceActionFailure: mock.reportFailure }));

import { POST } from "./route";

const body = {
  slug: "stay-a101",
  name: "ضيف VOYA",
  phone: "01012345678",
  email: "guest@example.test",
  check_in: "2027-03-01",
  check_out: "2027-03-04",
  guests: 2,
  message: "نحتاج سريراً إضافياً",
  consent: true,
  idempotency_key: "81111111-0000-4000-8000-000000000851",
  company: "",
};

function request(value: unknown = body, options: { origin?: string; url?: string; headers?: Record<string, string> } = {}) {
  const url = options.url ?? "http://localhost:3200/api/stay/requests";
  return new Request(url, {
    method: "POST",
    headers: {
      origin: options.origin ?? "http://localhost:3200",
      "content-type": "application/json",
      ...options.headers,
    },
    body: typeof value === "string" ? value : JSON.stringify(value),
  });
}

function serviceClient(config: Readonly<{ requests_enabled: boolean; privacy_notice_url: string | null; privacy_notice_version: string | null }> = {
  requests_enabled: true,
  privacy_notice_url: "https://voya.example/privacy",
  privacy_notice_version: "privacy-v1",
}) {
  const rpc = vi.fn().mockImplementation(async (name: string) => name === "get_voya_stay_public_request_config_v1"
    ? { data: [config], error: null }
    : { data: "aaaaaaaa-0000-0000-0000-000000000851", error: null });
  mock.createServiceClient.mockReturnValue({ rpc });
  return rpc;
}

afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
  delete process.env.VOYA_APP_URL;
  delete process.env.VOYA_STAY_REQUEST_HMAC_SECRET;
  delete process.env.VOYA_STAY_EDGE_RATE_LIMIT_ENABLED;
});

describe("public guest request route", () => {
  it("rejects cross-origin submissions before loading service credentials", async () => {
    const response = await POST(request(body, { origin: "https://attacker.example" }));
    expect(response.status).toBe(403);
    expect(mock.createServiceClient).not.toHaveBeenCalled();
  });

  it("returns an opaque receipt after routing a consented request into CRM only", async () => {
    process.env.VOYA_STAY_REQUEST_HMAC_SECRET = "test-only-secret-with-more-than-32-characters";
    const rpc = serviceClient();
    const response = await POST(request());
    const result = await response.json();

    expect(response.status).toBe(201);
    expect(result).toEqual({
      status: "received",
      message: "وصل طلبك إلى فريق VOYA لمراجعته والتواصل معك. لم يتم تأكيد الحجز.",
    });
    expect(rpc).toHaveBeenCalledWith("capture_voya_stay_lead_v1", expect.objectContaining({
      p_slug: "stay-a101",
      p_guest_name: "ضيف VOYA",
      p_phone: "+201012345678",
      p_email: "guest@example.test",
      p_consent_version: "privacy-v1",
      p_contact_consent: true,
      p_idempotency_key: body.idempotency_key,
      p_contact_fingerprint: expect.stringMatching(/^[0-9a-f]{64}$/u),
      p_payload_fingerprint: expect.stringMatching(/^[0-9a-f]{64}$/u),
    }));
    expect(rpc.mock.calls[1]?.[1]).not.toHaveProperty("p_organization_id");
  });

  it("fails closed when request capture is disabled or the HMAC secret is missing", async () => {
    serviceClient({ requests_enabled: false, privacy_notice_url: null, privacy_notice_version: null });
    const disabledResponse = await POST(request());
    expect(disabledResponse.status).toBe(503);

    vi.clearAllMocks();
    serviceClient();
    const missingSecretResponse = await POST(request());
    expect(missingSecretResponse.status).toBe(503);
  });

  it("keeps production request capture closed without the verified edge limit flag", async () => {
    vi.stubEnv("NODE_ENV", "production");
    process.env.VOYA_STAY_REQUEST_HMAC_SECRET = "test-only-secret-with-more-than-32-characters";
    const rpc = serviceClient();
    const response = await POST(request());
    expect(response.status).toBe(503);
    expect(rpc).toHaveBeenCalledTimes(1);
  });

  it("does not call CRM for invalid consent or a filled honeypot", async () => {
    process.env.VOYA_STAY_REQUEST_HMAC_SECRET = "test-only-secret-with-more-than-32-characters";
    const rpc = serviceClient();
    expect((await POST(request({ ...body, consent: false }))).status).toBe(400);
    expect((await POST(request({ ...body, company: "bot field" }))).status).toBe(202);
    expect(rpc).not.toHaveBeenCalled();
  });

  it("rejects bodies larger than the bounded request limit", async () => {
    const response = await POST(request({ ...body, message: "x".repeat(9000) }));
    expect(response.status).toBe(413);
    expect(mock.createServiceClient).not.toHaveBeenCalled();
  });
});
