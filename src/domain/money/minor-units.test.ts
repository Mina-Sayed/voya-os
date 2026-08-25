import { describe, expect, it } from "vitest";
import { formatMinorUnits, minorUnitsToMajor, parseMajorToMinor } from "./minor-units";

describe("money minor-unit helpers", () => {
  it("converts EGP major units to minor units without floating point", () => {
    expect(parseMajorToMinor("25000", "EGP")).toBe("2500000");
    expect(parseMajorToMinor("25000.50", "EGP")).toBe("2500050");
  });

  it("rejects unsupported precision and bigint overflow", () => {
    expect(() => parseMajorToMinor("1.001", "EGP")).toThrow();
    expect(() => parseMajorToMinor("92233720368547758.08", "EGP")).toThrow();
  });

  it("supports zero-decimal currencies", () => {
    expect(parseMajorToMinor("25000", "JPY")).toBe("25000");
    expect(() => parseMajorToMinor("25000.1", "JPY")).toThrow();
  });

  it("round-trips values above Number.MAX_SAFE_INTEGER precisely", () => {
    const minor = "900719925474099300";
    expect(minorUnitsToMajor(minor, "EGP")).toBe("9007199254740993");
    const formatted = formatMinorUnits(minor, "EGP", "en-US");
    expect(formatted).toBe("9,007,199,254,740,993");
  });
});
