import { expect, test } from "vitest";
import { createOrganizationId } from "../tenancy/organization";
import { createStayRange } from "./stay-range";
import {
  hasConfirmedBookingConflict,
  type ConfirmedBooking,
} from "./confirmed-booking";

const candidate: ConfirmedBooking = {
  id: "booking-candidate",
  organizationId: createOrganizationId("org-voya"),
  propertyId: "property-nile-view",
  status: "confirmed",
  stay: createStayRange("2026-08-01", "2026-08-04"),
};

test("finds a conflict only for confirmed overlapping stays in the same tenant and property", () => {
  const records: ConfirmedBooking[] = [
    {
      ...candidate,
      id: "booking-adjacent",
      stay: createStayRange("2026-08-04", "2026-08-07"),
    },
    {
      ...candidate,
      id: "booking-other-organization",
      organizationId: createOrganizationId("org-other"),
      stay: createStayRange("2026-08-02", "2026-08-06"),
    },
    {
      ...candidate,
      id: "booking-cancelled",
      status: "cancelled",
      stay: createStayRange("2026-08-02", "2026-08-06"),
    },
  ];

  expect(hasConfirmedBookingConflict(candidate, records)).toBe(false);

  expect(
    hasConfirmedBookingConflict(candidate, [
      ...records,
      {
        ...candidate,
        id: "booking-overlap",
        stay: createStayRange("2026-08-03", "2026-08-06"),
      },
    ]),
  ).toBe(true);
});
