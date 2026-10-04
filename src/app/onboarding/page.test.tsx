import { afterEach, beforeEach, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMemberships: vi.fn(),
  loadMfa: vi.fn(),
  redirect: vi.fn((path: string) => { throw new Error(`REDIRECT:${path}`); }),
}));

vi.mock("@/features/auth/workspace-context", () => ({
  loadActiveWorkspaceMemberships: mocks.loadMemberships,
  loadMfaAssurance: mocks.loadMfa,
}));
vi.mock("next/navigation", () => ({ redirect: mocks.redirect }));
vi.mock("@/features/organizations/onboarding-form", () => ({ OnboardingForm: () => <div>onboarding form</div> }));

import OnboardingPage from "./page";

beforeEach(() => {
  mocks.loadMemberships.mockResolvedValue({
    state: "authenticated",
    memberships: [{ id: "membership-suspended", organizationId: "org-a", organizationName: "مؤسسة أ", role: "owner", status: "suspended" }],
  });
  mocks.loadMfa.mockResolvedValue({ state: "satisfied" });
});

afterEach(() => vi.clearAllMocks());

test("routes suspended-only members to access pending instead of onboarding", async () => {
  await expect(OnboardingPage()).rejects.toThrow("REDIRECT:/access-pending");
});
