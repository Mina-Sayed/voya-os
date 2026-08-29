import { expect, test } from "vitest";
import { indexExecutableBookingChanges } from "./executable-amendments";

test("indexes executable confirmations and amendments from the trusted DB projection", () => {
  const result = indexExecutableBookingChanges([
    { booking_id: "booking-a", approval_request_id: "confirm-a", proposed_action: "booking.confirm" },
    { booking_id: "booking-b", approval_request_id: "amend-b", proposed_action: "booking.amend" },
  ]);

  expect(result.confirmationBookingIds.has("booking-a")).toBe(true);
  expect(result.confirmationBookingIds.has("booking-b")).toBe(false);
  expect(result.amendmentByBooking.get("booking-b")).toBe("amend-b");
});

test("keeps the first amendment if a defensive duplicate reaches the app", () => {
  const result = indexExecutableBookingChanges([
    { booking_id: "booking-a", approval_request_id: "newest", proposed_action: "booking.amend" },
    { booking_id: "booking-a", approval_request_id: "older", proposed_action: "booking.amend" },
  ]);

  expect(result.amendmentByBooking.get("booking-a")).toBe("newest");
});
