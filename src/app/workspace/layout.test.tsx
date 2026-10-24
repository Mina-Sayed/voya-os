import { afterEach, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMemberships: vi.fn(),
  redirect: vi.fn((path: string) => { throw new Error(`redirect:${path}`); }),
}));

vi.mock("next/navigation", () => ({ redirect: mocks.redirect }));
vi.mock("@/features/auth/workspace-context", () => ({ loadActiveWorkspaceMemberships: mocks.loadMemberships }));

import WorkspaceLayout from "./layout";

afterEach(() => vi.clearAllMocks());

test("redirects signed-out visitors before any workspace route renders", async () => {
  mocks.loadMemberships.mockResolvedValue({ state: "signed_out" });
  await expect(WorkspaceLayout({ children: "secret" })).rejects.toThrow("redirect:/sign-in");
});

test("passes signed-in users through so pages keep their own role and selection checks", async () => {
  // `loadActiveWorkspaceMemberships` only ever resolves `signed_out` or `authenticated`;
  // an invented state here would hide a wrong literal in the gate.
  for (const memberships of [[], [{ organizationId: "org-a", role: "owner" }]]) {
    mocks.loadMemberships.mockResolvedValue({ state: "authenticated", memberships });
    await expect(WorkspaceLayout({ children: "page" })).resolves.toBe("page");
  }
  expect(mocks.redirect).not.toHaveBeenCalled();
});
