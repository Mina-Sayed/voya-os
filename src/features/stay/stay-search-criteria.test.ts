import { describe, expect, it } from "vitest";
import { parseStaySearchCriteria } from "./stay-search-criteria";

describe("public stay search criteria", () => {
  it("accepts an empty search and normalizes optional filters", () => {
    expect(parseStaySearchCriteria(new URLSearchParams())).toEqual({
      destination: null, checkIn: null, checkOut: null, guests: null, bedrooms: null,
    });
  });

  it("trims public destination and validates stay dates and guest counts", () => {
    expect(parseStaySearchCriteria(new URLSearchParams({
      destination: "  المعادي ", check_in: "2027-01-01", check_out: "2027-01-04", guests: "3", bedrooms: "2",
    }))).toEqual({ destination: "المعادي", checkIn: "2027-01-01", checkOut: "2027-01-04", guests: 3, bedrooms: 2 });
  });

  it.each([
    { check_in: "2027-02-30", check_out: "2027-03-02" },
    { check_in: "2027-03-01", check_out: "2027-03-01" },
    { guests: "0" },
    { guests: "51" },
    { bedrooms: "-1" },
    { destination: "x".repeat(101) },
  ])("rejects invalid filters: %o", (filters) => {
    expect(parseStaySearchCriteria(new URLSearchParams(Object.entries(filters).map(([key, value]) => [key, String(value)])))).toBeNull();
  });
});
