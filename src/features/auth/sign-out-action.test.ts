import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createServerSupabaseClient: vi.fn(),
  deleteCookie: vi.fn(),
  redirect: vi.fn(),
  reportFailure: vi.fn(),
}));

vi.mock("next/headers", () => ({
  cookies: vi.fn().mockResolvedValue({ delete: mocks.deleteCookie }),
}));
vi.mock("next/navigation", () => ({ redirect: mocks.redirect }),);
vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createServerSupabaseClient }));
vi.mock("./workspace-context", () => ({
  ORGANIZATION_COOKIE: "voya-organization-id",
  reportWorkspaceActionFailure: mocks.reportFailure,
}));

import { signOutAction } from "./sign-out-action";

afterEach(() => vi.clearAllMocks());

describe("signOutAction", () => {
  it("revokes the provider session, clears workspace selection, and redirects", async () => {
    mocks.createServerSupabaseClient.mockResolvedValue({ auth: { signOut: vi.fn().mockResolvedValue({ error: null }) } });

    await signOutAction();

    expect(mocks.deleteCookie).toHaveBeenCalledWith("voya-organization-id");
    expect(mocks.redirect).toHaveBeenCalledWith("/sign-in");
    expect(mocks.reportFailure).not.toHaveBeenCalled();
  });

  it("still clears local state when provider sign-out fails", async () => {
    mocks.createServerSupabaseClient.mockRejectedValue(new Error("provider unavailable"));

    await signOutAction();

    expect(mocks.deleteCookie).toHaveBeenCalledWith("voya-organization-id");
    expect(mocks.redirect).toHaveBeenCalledWith("/sign-in");
    expect(mocks.reportFailure).toHaveBeenCalledWith("auth.sign_out", expect.any(Error));
  });

  it("handles a provider error returned from signOut", async () => {
    mocks.createServerSupabaseClient.mockResolvedValue({
      auth: { signOut: vi.fn().mockResolvedValue({ error: new Error("provider unavailable") }) },
    });

    await signOutAction();

    expect(mocks.deleteCookie).toHaveBeenCalledWith("voya-organization-id");
    expect(mocks.redirect).toHaveBeenCalledWith("/sign-in");
    expect(mocks.reportFailure).toHaveBeenCalledWith("auth.sign_out", expect.any(Error));
  });
});
