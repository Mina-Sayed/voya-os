import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AuditActivityPage } from "./audit-activity-page";

describe("AuditActivityPage", () => {
  it("renders a redacted successful operational event", () => {
    render(<AuditActivityPage events={[{ id: "audit-a", action: "availability_block.created", resourceType: "availability_block", outcome: "success", createdAt: "2026-07-22T00:00:00.000Z" }]} />);
    expect(screen.getByRole("heading", { name: "سجل النشاط" })).toBeInTheDocument();
    expect(screen.getByText("إضافة حظر توفر")).toBeInTheDocument();
    expect(screen.getByText("نجح")).toBeInTheDocument();
  });

  it("explains the absence of visible activity", () => {
    render(<AuditActivityPage events={[]} />);
    expect(screen.getByText("لا توجد أحداث مرئية ضمن صلاحياتك")).toBeInTheDocument();
  });
});
