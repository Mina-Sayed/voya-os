import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { TeamPage } from "./team-page";

const noop = vi.fn(async () => ({ status: "success" as const, message: "تم" }));

describe("TeamPage", () => {
  it("shows members, pending invitations, and owner controls without exposing invitation tokens", () => {
    render(
      <TeamPage
        canManage
        invite={noop}
        command={noop}
        members={[{
          id: "owner-membership",
          displayName: "مالك المؤسسة",
          role: "owner",
          status: "active",
          createdAt: "2026-08-12T10:00:00Z",
        }, {
          id: "operator-membership",
          displayName: "مشغل العمليات",
          role: "operator",
          status: "active",
          createdAt: "2026-08-12T11:00:00Z",
        }]}
        invitations={[{
          id: "invitation",
          email: "new@example.com",
          role: "manager",
          status: "pending",
          expiresAt: "2026-08-15T10:00:00Z",
          createdAt: "2026-08-12T10:00:00Z",
          acceptedAt: null,
          deliveryStatus: "pending",
        }]}
      />,
    );

    expect(screen.getByRole("heading", { name: "الفريق" })).toBeInTheDocument();
    expect(screen.getAllByText("مالك المؤسسة")).toHaveLength(2);
    expect(screen.getByText("مشغل العمليات")).toBeInTheDocument();
    expect(screen.getByText("new@example.com")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "إرسال الدعوة" })).toBeInTheDocument();
    expect(screen.getAllByRole("button", { name: "إعادة إرسال" })).toHaveLength(1);
    expect(screen.queryByText(/token|secret/i)).not.toBeInTheDocument();
  });

  it("keeps manager access read-only for team mutations", () => {
    render(
      <TeamPage
        canManage={false}
        invite={noop}
        command={noop}
        members={[]}
        invitations={[]}
      />,
    );

    expect(screen.getByText("يمكنك مراجعة الفريق والدعوات فقط؛ إجراءات الإدارة متاحة لمالك المؤسسة.")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "إرسال الدعوة" })).not.toBeInTheDocument();
  });
});
