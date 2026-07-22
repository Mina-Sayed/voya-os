import { render, screen } from "@testing-library/react";
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
