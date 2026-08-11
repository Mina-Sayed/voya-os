import { describe, expect, it, vi } from "vitest";

const runtime = vi.hoisted(() => ({
  loadWorkspaceContext: vi.fn(),
  loadLiveDashboardData: vi.fn(),
  createServerSupabaseClient: vi.fn(),
  redirect: vi.fn((path: string): never => {
    throw new Error(`redirect:${path}`);
  }),
}));

vi.mock("next/navigation", () => ({ redirect: runtime.redirect }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadWorkspaceContext: runtime.loadWorkspaceContext,
}));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: runtime.createServerSupabaseClient,
}));
vi.mock("@/features/dashboard/live-dashboard-data", () => ({
  loadLiveDashboardData: runtime.loadLiveDashboardData,
}));
vi.mock("@/features/dashboard/operations-dashboard", () => ({
  OperationsDashboard: (props: unknown) => props,
}));

import WorkspacePage from "./page";
import { dashboardData } from "@/features/dashboard/dashboard-data";

describe("WorkspacePage", () => {
  it("redirects an MFA-required server context before protected content can render", async () => {
    runtime.loadWorkspaceContext.mockResolvedValue({ state: "mfa_required" });

    await expect(WorkspacePage()).rejects.toThrow("redirect:/mfa");
    expect(runtime.redirect).toHaveBeenCalledWith("/mfa");
  });
  it("renders the accepted live dashboard for a ready membership", async () => {
    const membership = {
      id: "membership-qa",
      organizationId: "org-qa",
      organizationName: "فُويا QA",
      role: "owner",
      status: "active" as const,
    };
    const liveData = { ...dashboardData, isPreview: false, organizationName: membership.organizationName };
    runtime.loadWorkspaceContext.mockResolvedValue({ state: "ready", membership });
    runtime.createServerSupabaseClient.mockResolvedValue({});
    runtime.loadLiveDashboardData.mockResolvedValue(liveData);

    const result = await WorkspacePage();

    expect(runtime.loadLiveDashboardData).toHaveBeenCalledWith({}, membership, "فريق التشغيل");
    expect(result).toMatchObject({ props: { data: liveData } });
  });
});
