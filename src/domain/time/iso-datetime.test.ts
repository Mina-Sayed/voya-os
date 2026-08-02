import { expect, test } from "vitest";
import { parseIsoDateTime } from "./iso-datetime";

test("normalizes a valid date-time to an ISO instant", () => {
  expect(parseIsoDateTime("2027-01-01T12:30:00Z")).toBe("2027-01-01T12:30:00.000Z");
});

test("rejects missing and malformed date-time input", () => {
  expect(parseIsoDateTime(null)).toBeNull();
  expect(parseIsoDateTime("  ")).toBeNull();
  expect(parseIsoDateTime("not-a-date")).toBeNull();
  expect(parseIsoDateTime("2027-02-31T12:30")).toBeNull();
  expect(parseIsoDateTime("2027-01-01T24:00")).toBeNull();
});
