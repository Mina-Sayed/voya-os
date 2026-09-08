import { expect, test } from "vitest";
import { formatLocalDateTime, isSupportedTimezone, parseIsoDateTime } from "./iso-datetime";

test("normalizes a valid date-time to an ISO instant", () => {
  expect(parseIsoDateTime("2027-01-01T12:30:00Z", "UTC")).toBe("2027-01-01T12:30:00.000Z");
});

test("rejects missing and malformed date-time input", () => {
  expect(parseIsoDateTime(null, "UTC")).toBeNull();
  expect(parseIsoDateTime("  ", "UTC")).toBeNull();
  expect(parseIsoDateTime("not-a-date", "UTC")).toBeNull();
  expect(parseIsoDateTime("2027-02-31T12:30", "UTC")).toBeNull();
  expect(parseIsoDateTime("2027-01-01T24:00", "UTC")).toBeNull();
});

test("interprets offset-free local date-times in the supplied IANA timezone", () => {
  expect(parseIsoDateTime("2026-09-05T12:00", "Africa/Cairo")).toBe("2026-09-05T09:00:00.000Z");
  expect(parseIsoDateTime("2026-07-01T12:00", "America/New_York")).toBe("2026-07-01T16:00:00.000Z");
});

test("rejects nonexistent or ambiguous daylight-saving local times", () => {
  expect(parseIsoDateTime("2026-03-08T02:30", "America/New_York")).toBeNull();
  expect(parseIsoDateTime("2026-11-01T01:30", "America/New_York")).toBeNull();
});

test("rejects an invalid IANA timezone instead of using the server timezone", () => {
  expect(parseIsoDateTime("2026-09-05T12:00", "Cairo-local")).toBeNull();
});

test("formats stored instants for datetime-local inputs in the organization zone", () => {
  // Cairo noon is 09:00Z in September; the input must show 12:00, not 09:00.
  expect(formatLocalDateTime("2026-09-05T09:00:00.000Z", "Africa/Cairo")).toBe("2026-09-05T12:00");
  expect(formatLocalDateTime("2026-09-05T09:00:00.000Z", "UTC")).toBe("2026-09-05T09:00");
  // Round-trip: formatting then parsing restores the same instant.
  expect(parseIsoDateTime(formatLocalDateTime("2026-09-05T09:00:00.000Z", "Africa/Cairo"), "Africa/Cairo")).toBe("2026-09-05T09:00:00.000Z");
  expect(formatLocalDateTime(null, "Africa/Cairo")).toBe("");
  expect(formatLocalDateTime("not-a-date", "Africa/Cairo")).toBe("");
  expect(formatLocalDateTime("2026-09-05T09:00:00.000Z", "Cairo-local")).toBe("");
});

test("detects runtime-supported IANA timezones", () => {
  expect(isSupportedTimezone("Africa/Cairo")).toBe(true);
  expect(isSupportedTimezone("UTC")).toBe(true);
  expect(isSupportedTimezone("Cairo-local")).toBe(false);
  expect(isSupportedTimezone("  ")).toBe(false);
});
