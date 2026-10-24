import { describe, expect, it } from "vitest";
import { hmacStayContactFingerprint, hmacStayRequestFingerprint, validateVoyaStayRequest } from "./public-request";

describe("VOYA Stay guest request validation", () => {
  it("normalizes contact and accepts a complete consented request", () => {
    expect(validateVoyaStayRequest({
      slug: "stay-a101",
      name: "  ضيف VOYA  ",
      phone: "01012345678",
      email: " Guest@Example.Test ",
      check_in: "2027-03-01",
      check_out: "2027-03-04",
      guests: 2,
      message: "نحتاج سريراً إضافياً",
      consent: true,
      idempotency_key: "81111111-0000-4000-8000-000000000841",
      company: "",
    })).toEqual({
      slug: "stay-a101", name: "ضيف VOYA", phone: "+201012345678", email: "guest@example.test",
      checkIn: "2027-03-01", checkOut: "2027-03-04", guests: 2,
      message: "نحتاج سريراً إضافياً", consent: true,
      idempotencyKey: "81111111-0000-4000-8000-000000000841", honeypot: "",
    });
  });

  it("requires valid contact, dates, and explicit consent", () => {
    const base = {
      slug: "stay-a101", name: "Guest", phone: "", email: "", check_in: "2027-03-01",
      check_out: "2027-03-04", guests: 2, message: "", consent: true,
      idempotency_key: "81111111-0000-4000-8000-000000000842", company: "",
    };
    expect(validateVoyaStayRequest(base)).toBeNull();
    expect(validateVoyaStayRequest({ ...base, phone: "+201012345678", consent: false })).toBeNull();
    expect(validateVoyaStayRequest({ ...base, email: "guest@example.test", check_in: "2027-02-30" })).toBeNull();
    expect(validateVoyaStayRequest({ ...base, email: "guest@example.test", guests: 51 })).toBeNull();
  });

  it("stores keyed contact and payload fingerprints without retaining clear contact in the fingerprint", () => {
    const request = validateVoyaStayRequest({
      slug: "stay-a101", name: "Guest", phone: "+201012345678", email: "guest@example.test",
      check_in: "2027-03-01", check_out: "2027-03-04", guests: 2, message: "",
      consent: true, idempotency_key: "81111111-0000-4000-8000-000000000843", company: "",
    });
    if (!request) throw new Error("Valid request did not normalize.");
    const secret = "test-only-secret-with-more-than-32-characters";
    const contactFingerprint = hmacStayContactFingerprint(secret, request);
    const requestFingerprint = hmacStayRequestFingerprint(secret, request, "privacy-v1");
    expect(contactFingerprint).toMatch(/^[0-9a-f]{64}$/u);
    expect(requestFingerprint).toMatch(/^[0-9a-f]{64}$/u);
    expect(contactFingerprint).not.toContain("201012345678");
    expect(hmacStayContactFingerprint(`${secret}-rotated`, request)).not.toBe(contactFingerprint);
  });
});
