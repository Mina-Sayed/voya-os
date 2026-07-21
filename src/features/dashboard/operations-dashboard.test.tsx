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
