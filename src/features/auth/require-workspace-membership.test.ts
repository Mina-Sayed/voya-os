import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadWorkspaceContext: vi.fn(),
  redirect: vi.fn((path: string) => {
    throw new Error(`REDIRECT:${path}`);
  }),
}));

vi.mock("./workspace-context", () => ({
  loadWorkspaceContext: mocks.loadWorkspaceContext,
}));
vi.mock("next/navigation", () => ({ redirect: mocks.redirect }));

import { requireWorkspaceMembership } from "./require-workspace-membership";

const membership = {
  id: "membership-a",
  organizationId: "organization-a",
  organizationName: "Voya Alpha",
  role: "manager",
  status: "active" as const,
};

afterEach(() => vi.clearAllMocks());

describe("requireWorkspaceMembership", () => {
  it.each([
    [{ state: "signed_out" }, "/sign-in"],
    [{ state: "mfa_required", reason: "challenge" }, "/security/mfa?reason=challenge"],
    [{ state: "selection_required", memberships: [membership] }, "/workspace"],
    [{ state: "pending" }, "/onboarding"],
  ] as const)("redirects %j to %s", async (context, path) => {
    mocks.loadWorkspaceContext.mockResolvedValue(context);

    await expect(requireWorkspaceMembership()).rejects.toThrow(`REDIRECT:${path}`);
    expect(mocks.redirect).toHaveBeenCalledWith(path);
  });

  it("redirects a member whose role is outside the allowed set", async () => {
    mocks.loadWorkspaceContext.mockResolvedValue({ state: "ready", membership });

    await expect(requireWorkspaceMembership(new Set(["owner"]))).rejects.toThrow("REDIRECT:/access-pending");
  });

  it("returns the server-owned membership when the role is allowed", async () => {
    mocks.loadWorkspaceContext.mockResolvedValue({ state: "ready", membership });

    await expect(requireWorkspaceMembership(new Set(["manager", "owner"]))).resolves.toEqual(membership);
    expect(mocks.redirect).not.toHaveBeenCalled();
  });
});
