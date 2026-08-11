import { fireEvent, render, screen, within } from "@testing-library/react";
import { expect, test } from "vitest";
import { dashboardData } from "./dashboard-data";
import { OperationsDashboard } from "./operations-dashboard";

test("renders the Arabic operations heading and preview notice", () => {
  render(<OperationsDashboard data={dashboardData} />);

  expect(
    screen.getByRole("heading", { name: "صباحك منظّم" }),
  ).toBeInTheDocument();
  expect(screen.getByText("بيانات تجريبية للعرض فقط")).toBeInTheDocument();
});

test("labels live workspace data without changing the accepted dashboard shell", () => {
  render(<OperationsDashboard data={{ ...dashboardData, isPreview: false }} />);

  expect(screen.getByText("بيانات حية من مساحة العمل")).toBeInTheDocument();
  expect(screen.queryByText("بيانات تجريبية للعرض فقط")).not.toBeInTheDocument();
});

test("renders intentional empty states instead of blank dashboard regions", () => {
  render(<OperationsDashboard data={{ ...dashboardData, isPreview: false, bookings: [], approvals: [] }} />);

  expect(screen.getByText("لا توجد إقامات قريبة ضمن مساحة العمل")).toBeInTheDocument();
  expect(screen.getByText("لا توجد قرارات معلّقة")).toBeInTheDocument();
});

test("labels the stay ribbon as a list of scheduled stays", () => {
  render(<OperationsDashboard data={dashboardData} />);

  expect(screen.getByRole("list", { name: "إقامات الأيام القادمة" })).toBeInTheDocument();
});

test("routes sidebar workspace links to their protected pages", () => {
  render(<OperationsDashboard data={dashboardData} />);

  expect(screen.getByRole("link", { name: "الإقامات" })).toHaveAttribute("href", "/workspace/bookings");
  expect(screen.getByRole("link", { name: "العقارات" })).toHaveAttribute("href", "/workspace/properties");
  expect(screen.getByRole("link", { name: "العملاء" })).toHaveAttribute("href", "/workspace/clients");
});

test("keeps unavailable dashboard actions and settings visibly disabled", () => {
  render(<OperationsDashboard data={dashboardData} />);

  expect(screen.getByRole("button", { name: "التنبيهات — قريبًا" })).toBeDisabled();
  expect(screen.getByRole("button", { name: "حساب المشغّل — قريبًا" })).toBeDisabled();
  expect(screen.getByRole("button", { name: "المزيد من خيارات الوصول — قريبًا" })).toBeDisabled();
  expect(screen.getByRole("button", { name: "عرض قائمة القرارات — قريبًا" })).toBeDisabled();
  expect(screen.getAllByTitle("قريبًا")).toHaveLength(6);
  expect(screen.queryByRole("link", { name: "الإعدادات" })).not.toBeInTheDocument();
  expect(screen.getByText("الإعدادات").parentElement).toHaveAttribute("aria-disabled", "true");
});

test("opens mobile navigation, retains disabled destinations, and closes with Escape", () => {
  render(<OperationsDashboard data={dashboardData} />);

  const trigger = screen.getByRole("button", { name: "فتح التنقل" });
  expect(trigger).toHaveAttribute("aria-expanded", "false");

  fireEvent.click(trigger);

  const mobileNavigation = screen.getByRole("navigation", { name: "التنقل على الهاتف" });
  expect(mobileNavigation).toBeVisible();
  expect(within(mobileNavigation).getByRole("link", { name: "نظرة عامة" })).toHaveAttribute("href", "/workspace");
  expect(within(mobileNavigation).getByRole("link", { name: "الإقامات" })).toHaveAttribute("href", "/workspace/bookings");
  expect(within(mobileNavigation).getByRole("link", { name: "العقارات" })).toHaveAttribute("href", "/workspace/properties");
  expect(within(mobileNavigation).getByRole("link", { name: "العملاء" })).toHaveAttribute("href", "/workspace/clients");
  expect(within(mobileNavigation).getByText("الماليات").parentElement).toHaveAttribute("aria-disabled", "true");
  expect(within(mobileNavigation).getByText("الإعدادات").parentElement).toHaveAttribute("aria-disabled", "true");

  fireEvent.keyDown(window, { key: "Escape" });

  expect(screen.queryByRole("navigation", { name: "التنقل على الهاتف" })).not.toBeInTheDocument();
});
