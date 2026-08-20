import { describe, expect, it } from "vitest";
import { failure, moneyDtoSchema, success } from "./contracts";

describe("application contracts", () => {
  it("accepts integer minor-unit money and rejects floats", () => {
    expect(moneyDtoSchema.parse({ amountMinor: "2500000", currency: "EGP" })).toEqual({ amountMinor: "2500000", currency: "EGP" });
    expect(moneyDtoSchema.safeParse({ amountMinor: "25000.00", currency: "EGP" }).success).toBe(false);
    expect(moneyDtoSchema.safeParse({ amountMinor: "2500000", currency: "egp" }).success).toBe(false);
  });

  it("creates typed success and safe failure results with request correlation", () => {
    expect(success({ id: "booking" }, "request-1")).toEqual({ status: "success", data: { id: "booking" }, requestId: "request-1" });
    expect(failure("request-2", "denied", "غير مسموح.")).toEqual({ status: "error", code: "denied", message: "غير مسموح.", requestId: "request-2" });
  });
});
