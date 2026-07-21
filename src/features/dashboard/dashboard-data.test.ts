import { expect, test } from "vitest";
import { dashboardData } from "./dashboard-data";

test("keeps all dashboard fixture records in the active organization", () => {
  const recordOrganizations = dashboardData.bookings.map(
    (booking) => booking.organizationId,
  );

  expect(new Set(recordOrganizations)).toEqual(
    new Set([dashboardData.organizationId]),
  );
});

test("identifies the dashboard as preview data rather than live operations data", () => {
  expect(dashboardData.isPreview).toBe(true);
});
