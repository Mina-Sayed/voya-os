import { afterEach, describe, expect, it, vi } from "vitest";

const runtime = vi.hoisted(() => ({
  createBrowserClient: vi.fn(),
}));

vi.mock("@supabase/ssr", () => ({
  createBrowserClient: runtime.createBrowserClient,
}));

import { createBrowserSupabaseClient } from "./browser-client";

afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("createBrowserSupabaseClient", () => {
  it("creates the browser client with public Supabase configuration only", () => {
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.supabase.co/");
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "publishable-key");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "server-secret");
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("NEXT_PUBLIC_VOYA_AUTH_E2E_LOCAL", "1");
    const client = { auth: {} };
    runtime.createBrowserClient.mockReturnValue(client);

    expect(createBrowserSupabaseClient()).toBe(client);
    expect(runtime.createBrowserClient).toHaveBeenCalledWith(
      "https://project.supabase.co",
      "publishable-key",
    );
  });

  it("rejects an HTTP project URL in production browser code", () => {
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "http://project.supabase.co");
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "publishable-key");
    vi.stubEnv("NODE_ENV", "production");

    expect(() => createBrowserSupabaseClient()).toThrow("HTTPS");
    expect(runtime.createBrowserClient).not.toHaveBeenCalled();
  });
});
