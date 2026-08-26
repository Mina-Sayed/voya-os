import { expect, test } from "vitest";
import { selectLatestExecutableAmendments } from "./executable-amendments";

test("selects only approved unexpired amendment requests", () => {
  const now = Date.parse("2026-08-26T20:00:00Z");
  const result = selectLatestExecutableAmendments([
    { id: "expired", resource_id: "booking-a", proposed_action: "booking.amend", status: "approved", expires_at: "2026-08-26T19:59:59Z" },
    { id: "valid", resource_id: "booking-b", proposed_action: "booking.amend", status: "approved", expires_at: "2026-08-26T21:00:00Z" },
    { id: "pending", resource_id: "booking-c", proposed_action: "booking.amend", status: "pending", expires_at: "2026-08-26T21:00:00Z" },
    { id: "cancel", resource_id: "booking-d", proposed_action: "booking.cancel", status: "approved", expires_at: "2026-08-26T21:00:00Z" },
  ], now);

  expect(result.get("booking-a")).toBeUndefined();
  expect(result.get("booking-b")).toBe("valid");
  expect(result.get("booking-c")).toBeUndefined();
  expect(result.get("booking-d")).toBeUndefined();
});

test("keeps the first executable amendment from a newest-first projection", () => {
  const now = Date.parse("2026-08-26T20:00:00Z");
  const result = selectLatestExecutableAmendments([
    { id: "newest", resource_id: "booking-a", proposed_action: "booking.amend", status: "approved", expires_at: "2026-08-27T20:00:00Z" },
    { id: "older", resource_id: "booking-a", proposed_action: "booking.amend", status: "approved", expires_at: "2026-08-27T20:00:00Z" },
  ], now);

  expect(result.get("booking-a")).toBe("newest");
});
