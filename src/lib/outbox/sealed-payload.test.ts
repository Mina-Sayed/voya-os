import { describe, expect, it } from "vitest";
import { sealOutboxPayload, unsealOutboxPayload } from "./sealed-payload";

const key = Buffer.alloc(32, 7).toString("base64");

describe("sealed outbox payloads", () => {
  it("round-trips a one-time delivery secret without storing it in plaintext", () => {
    const sealed = sealOutboxPayload("one-time-token", key);

    expect(sealed).not.toContain("one-time-token");
    expect(unsealOutboxPayload(sealed, key)).toBe("one-time-token");
  });

  it("rejects a payload when the worker key is wrong", () => {
    const sealed = sealOutboxPayload("one-time-token", key);

    expect(() => unsealOutboxPayload(sealed, Buffer.alloc(32, 8).toString("base64"))).toThrow("sealed outbox payload");
  });

  it("rejects weak or missing encryption keys", () => {
    expect(() => sealOutboxPayload("secret", "short")).toThrow("OUTBOX_PAYLOAD_ENCRYPTION_KEY");
  });
});
