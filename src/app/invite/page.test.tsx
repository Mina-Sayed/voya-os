import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ loadMemberships: vi.fn() }));
vi.mock("@/features/auth/workspace-context", () => ({ loadActiveWorkspaceMemberships: mocks.loadMemberships }));
vi.mock("./actions", () => ({ acceptOrganizationInvitationAction: vi.fn() }));
vi.mock("next/navigation", () => ({ useRouter: () => ({ replace: vi.fn() }) }));

import InvitePage from "./page";

const token = "b".repeat(64);

afterEach(() => vi.clearAllMocks());

describe("/invite", () => {
  it("offers a sign-in continuation for a signed-out recipient", async () => {
    mocks.loadMemberships.mockResolvedValue({ state: "signed_out" });
    render(await InvitePage({ searchParams: Promise.resolve({ token }) }));

    expect(screen.getByRole("heading", { name: "سجّل الدخول لقبول الدعوة" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /الانتقال إلى تسجيل الدخول/ })).toHaveAttribute("href", `/sign-in?token=${token}`);
  });

  it("renders the authenticated accept action for a valid token", async () => {
    mocks.loadMemberships.mockResolvedValue({ state: "authenticated", memberships: [] });
    render(await InvitePage({ searchParams: Promise.resolve({ token }) }));

    expect(screen.getByRole("button", { name: /قبول الدعوة/ })).toBeInTheDocument();
    expect(screen.getByDisplayValue(token)).toBeInTheDocument();
  });

  it("rejects an invalid token without querying session state", async () => {
    render(await InvitePage({ searchParams: Promise.resolve({ token: "invalid" }) }));

    expect(screen.getByText("رابط الدعوة غير صالح أو ناقص.")).toBeInTheDocument();
    expect(mocks.loadMemberships).not.toHaveBeenCalled();
  });
});
