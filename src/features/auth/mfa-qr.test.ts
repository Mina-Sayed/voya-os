import { describe, expect, it } from "vitest";
import { resolveMfaQrImageSource } from "./mfa-qr";

describe("resolveMfaQrImageSource", () => {
  it("preserves data URLs and safely encodes raw SVG", () => {
    expect(resolveMfaQrImageSource("data:image/png;base64,abc")).toBe("data:image/png;base64,abc");
    expect(resolveMfaQrImageSource("<svg><text>Voya</text></svg>")).toBe("data:image/svg+xml;utf-8,%3Csvg%3E%3Ctext%3EVoya%3C%2Ftext%3E%3C%2Fsvg%3E");
  });
});
