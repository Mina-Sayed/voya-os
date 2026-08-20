import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AuditActivityPage } from "./audit-activity-page";

describe("AuditActivityPage", () => {
  const filters = { from: "", to: "", actorMembershipId: "", action: "", resourceType: "" } as const;
  const members = [{ id: "member-a", displayName: "Tenant A user", role: "owner", status: "active" }] as const;
  const event = {
    id: "audit-a",
    action: "availability_block.created",
    resourceType: "availability_block",
    resourceId: "resource-a",
    actorType: "user",
    actorMembershipId: "member-a",
    actorDisplayName: "Tenant A user",
    outcome: "success" as const,
    reasonCode: "user_edit",
    beforeDelta: { status: "open" },
    afterDelta: { status: "blocked" },
    createdAt: "2026-07-22T00:00:00.000Z",
  };

  it("renders a redacted successful operational event", () => {
    render(<AuditActivityPage events={[event]} filters={filters} members={members} />);
    expect(screen.getByRole("heading", { name: "سجل النشاط" })).toBeInTheDocument();
    expect(screen.getByText("إضافة حظر توفر")).toBeInTheDocument();
    expect(screen.getByText("نجح")).toBeInTheDocument();
  });

  it("renders filter controls and redacted change details", () => {
    render(<AuditActivityPage events={[event]} filters={{ ...filters, action: "availability_block.created", from: "2026-07-22" }} members={members} />);
    expect(screen.getByRole("heading", { name: "تصفية سجل النشاط" })).toBeInTheDocument();
    expect(screen.getByDisplayValue("availability_block.created")).toBeInTheDocument();
    expect(screen.getByRole("combobox", { name: "العضو المنفذ" })).toHaveValue("");
    expect(screen.getByText("تفاصيل الحدث")).toBeInTheDocument();
    expect(screen.getByText("availability_block · Tenant A user")).toBeInTheDocument();
  });

  it("explains the absence of visible activity", () => {
    render(<AuditActivityPage events={[]} filters={filters} members={members} />);
    expect(screen.getByText("لا توجد أحداث مرئية ضمن الفلاتر والصلاحيات")).toBeInTheDocument();
  });
});
