import { describe, expect, it, vi } from "vitest";

const runtime = vi.hoisted(() => ({
  loadWorkspaceContext: vi.fn(),
  redirect: vi.fn((path: string): never => {
    throw new Error(`redirect:${path}`);
  }),
}));

vi.mock("next/navigation", () => ({ redirect: runtime.redirect }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadWorkspaceContext: runtime.loadWorkspaceContext,
}));

import WorkspacePage from "./page";

describe("WorkspacePage", () => {
  it("redirects an MFA-required server context before protected content can render", async () => {
    runtime.loadWorkspaceContext.mockResolvedValue({ state: "mfa_required" });

    await expect(WorkspacePage()).rejects.toThrow("redirect:/mfa");
    expect(runtime.redirect).toHaveBeenCalledWith("/mfa");
  });
});
