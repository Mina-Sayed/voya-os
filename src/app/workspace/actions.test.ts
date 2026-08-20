import { describe, expect, it, vi } from "vitest";

const runtime = vi.hoisted(() => ({
  cookies: vi.fn(),
  loadActiveWorkspaceMemberships: vi.fn(),
  redirect: vi.fn((path: string): never => {
    throw new Error(`redirect:${path}`);
  }),
}));

vi.mock("next/headers", () => ({ cookies: runtime.cookies }));
vi.mock("next/navigation", () => ({ redirect: runtime.redirect }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadActiveWorkspaceMemberships: runtime.loadActiveWorkspaceMemberships,
  ORGANIZATION_COOKIE: "voya-organization-id",
}));

import { selectOrganizationAction } from "./actions";

describe("selectOrganizationAction", () => {
  it("redirects an MFA-required session before reading or changing organization state", async () => {
    runtime.loadActiveWorkspaceMemberships.mockResolvedValue({ state: "mfa_required" });
    const formData = new FormData();
    formData.set("organization_id", "organization-a");

    await expect(selectOrganizationAction(formData)).rejects.toThrow("redirect:/mfa");
    expect(runtime.redirect).toHaveBeenCalledWith("/mfa");
    expect(runtime.cookies).not.toHaveBeenCalled();
  });
});
