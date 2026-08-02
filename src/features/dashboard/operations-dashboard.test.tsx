import { render, screen } from "@testing-library/react";
import { expect, test } from "vitest";
import { dashboardData } from "./dashboard-data";
import { OperationsDashboard } from "./operations-dashboard";

test("renders the live Arabic operations dashboard and its tenant-safe actions", () => {
  render(<OperationsDashboard data={{ ...dashboardData, isPreview: false }} />);

  expect(screen.getByRole("heading", { name: "لوحة التشغيل" })).toBeInTheDocument();
  expect(screen.getByText("مزامنة المؤسسة مفعّلة")).toBeInTheDocument();
  expect(screen.getByRole("link", { name: "إضافة طلب" })).toHaveAttribute("href", "/workspace/leads");
  expect(screen.getByRole("link", { name: "فتح مسار المراجعة" })).toHaveAttribute("href", "/workspace/approvals");
});

test("shows live lead rows and a useful empty state", () => {
  render(<OperationsDashboard data={{ ...dashboardData, recentLeads: [] }} />);

  expect(screen.getByText("لا توجد طلبات بعد")).toBeInTheDocument();
  expect(screen.getByRole("link", { name: "إضافة أول طلب" })).toHaveAttribute("href", "/workspace/leads");
});
