import { afterEach, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  consume: vi.fn(),
  createServerClient: vi.fn(),
  report: vi.fn(),
}));

vi.mock("@/lib/security/auth-rate-limit", () => ({
  AuthRateLimitUnavailable: class AuthRateLimitUnavailable extends Error {},
  consumeAuthRateLimit: mocks.consume,
}));
vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createServerClient }));
vi.mock("@/lib/observability/operational-error", () => ({ reportOperationalError: mocks.report }));
vi.mock("@/features/auth/application-origin", () => ({
  resolveApplicationOrigin: () => new URL("https://voya.test"),
  internalApplicationUrl: (origin: URL, path: string) => new URL(path, origin),
}));

import { requestPasswordResetAction } from "./actions";

const idle = { status: "idle" as const, message: "" };
function form(email: string) {
  const data = new FormData();
  data.set("email", email);
  return data;
}

afterEach(() => vi.clearAllMocks());

test("logs SMTP 5xx failures with a request id and keeps the user message generic", async () => {
  mocks.consume.mockResolvedValue(true);
  const error = { status: 500, code: "unexpected_failure", message: "535 5.7.8 Username and Password not accepted" };
  mocks.createServerClient.mockResolvedValue({ auth: { resetPasswordForEmail: vi.fn().mockResolvedValue({ error }) } });

  await expect(requestPasswordResetAction(idle, form("staff@voya.test"))).resolves.toEqual({ status: "retry", message: "تعذر إرسال رسالة الاستعادة الآن." });
  expect(mocks.report).toHaveBeenCalledWith({
    operation: "auth.password_reset",
    requestId: expect.stringMatching(/^[0-9a-f-]{36}$/u),
    code: "password_reset_delivery_failed",
    outcome: "unavailable",
    cause: error,
  });
});

test("classifies non-5xx provider errors separately", async () => {
  mocks.consume.mockResolvedValue(true);
  mocks.createServerClient.mockResolvedValue({ auth: { resetPasswordForEmail: vi.fn().mockResolvedValue({ error: { status: 429 } }) } });

  await requestPasswordResetAction(idle, form("staff@voya.test"));
  expect(mocks.report).toHaveBeenCalledWith(expect.objectContaining({ code: "password_reset_rejected" }));
});

test("does not log when the reset email is accepted", async () => {
  mocks.consume.mockResolvedValue(true);
  mocks.createServerClient.mockResolvedValue({ auth: { resetPasswordForEmail: vi.fn().mockResolvedValue({ error: null }) } });

  await expect(requestPasswordResetAction(idle, form("staff@voya.test"))).resolves.toMatchObject({ status: "sent" });
  expect(mocks.report).not.toHaveBeenCalled();
});
