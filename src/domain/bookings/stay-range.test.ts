import { expect, test } from "vitest";
import { createStayRange, stayRangesOverlap } from "./stay-range";

test("allows adjacent stays and rejects overlapping confirmed stays", () => {
  const first = createStayRange("2026-08-01", "2026-08-04");
  const adjacent = createStayRange("2026-08-04", "2026-08-07");
  const overlap = createStayRange("2026-08-03", "2026-08-06");

  expect(stayRangesOverlap(first, adjacent)).toBe(false);
  expect(stayRangesOverlap(first, overlap)).toBe(true);
});

test("rejects an empty or reversed stay range", () => {
  expect(() => createStayRange("2026-08-04", "2026-08-04")).toThrow(
    "Check-out must be after check-in",
  );
  expect(() => createStayRange("", "2026-08-04")).toThrow("Stay dates are required");
});
