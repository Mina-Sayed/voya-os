import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadWorkspaceContext: vi.fn(),
  redirect: vi.fn((path: string) => {
    throw new Error(`REDIRECT:${path}`);
  }),
}));

vi.mock("@/features/auth/workspace-context", () => ({
  loadWorkspaceContext: mocks.loadWorkspaceContext,
}));
vi.mock("next/navigation", () => ({ redirect: mocks.redirect }));
vi.mock("@/features/dashboard/live-dashboard-data", () => ({ loadLiveDashboardData: vi.fn() }));
vi.mock("@/features/dashboard/operations-dashboard", () => ({ OperationsDashboard: () => null }));
vi.mock("@/features/workspace/workspace-shell", () => ({ WorkspaceShell: () => null }));
vi.mock("./actions", () => ({ selectOrganizationAction: vi.fn() }));

import WorkspacePage from "./page";

afterEach(() => vi.clearAllMocks());

describe("/workspace root redirects", () => {
  it.each([
    [{ state: "signed_out" }, "/sign-in"],
    [{ state: "pending" }, "/onboarding"],
    [{ state: "mfa_required", reason: "challenge" }, "/security/mfa?reason=challenge"],
  ] as const)("redirects %j to %s", async (context, path) => {
    mocks.loadWorkspaceContext.mockResolvedValue(context);

    await expect(WorkspacePage()).rejects.toThrow(`REDIRECT:${path}`);
    expect(mocks.redirect).toHaveBeenCalledWith(path);
  });
});
