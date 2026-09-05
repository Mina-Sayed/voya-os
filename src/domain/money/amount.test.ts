import { describe, expect, test } from "vitest";
import {
  currencyMinorDigits,
  formatMinorAmount,
  formatMinorAmountForInput,
  parseMajorAmountToMinor,
} from "./amount";

describe("money unit conversion", () => {
  test("converts EGP major units to exact minor units", () => {
    expect(parseMajorAmountToMinor("2500", "EGP")).toBe("250000");
    expect(parseMajorAmountToMinor("2500.50", "EGP")).toBe("250050");
    expect(parseMajorAmountToMinor("0.5", "EGP")).toBe("50");
  });

  test("uses the currency-specific fraction scale", () => {
    expect(currencyMinorDigits("JPY")).toBe(0);
    expect(parseMajorAmountToMinor("2500", "JPY")).toBe("2500");
    expect(parseMajorAmountToMinor("2500.0", "JPY")).toBeNull();
    expect(currencyMinorDigits("KWD")).toBe(3);
    expect(parseMajorAmountToMinor("1.234", "KWD")).toBe("1234");
  });

  test("rejects excess precision, malformed values, and bigint overflow", () => {
    expect(parseMajorAmountToMinor("2500.001", "EGP")).toBeNull();
    expect(parseMajorAmountToMinor("01.00", "EGP")).toBeNull();
    expect(parseMajorAmountToMinor("2500,00", "EGP")).toBeNull();
    expect(parseMajorAmountToMinor("92233720368547758.08", "EGP")).toBeNull();
  });

  test("formats large stored amounts without converting them to Number", () => {
    expect(formatMinorAmount("250050", "EGP", "en-US")).toBe("2,500.50");
    expect(formatMinorAmount("9007199254740993", "EGP", "en-US")).toBe("90,071,992,547,409.93");
    expect(formatMinorAmountForInput("250050", "EGP")).toBe("2500.50");
    expect(formatMinorAmountForInput("2500", "JPY")).toBe("2500");
  });
});
