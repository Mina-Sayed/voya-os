import { describe, expect, it } from "vitest";
import sharp from "sharp";
import { transformStayImageForPublication } from "./public-media";

describe("VOYA Stay public media", () => {
  it("re-encodes approved photos as size-limited metadata-free WebP", async () => {
    const source = await sharp({
      create: { width: 3200, height: 1600, channels: 3, background: { r: 23, g: 59, b: 52 } },
    }).jpeg().withMetadata().toBuffer();

    const result = await transformStayImageForPublication(source);
    const metadata = await sharp(result).metadata();

    expect(metadata.format).toBe("webp");
    expect(metadata.width).toBe(2000);
    expect(metadata.height).toBe(1000);
    expect(metadata.exif).toBeUndefined();
    expect(metadata.icc).toBeUndefined();
    expect(result.byteLength).toBeLessThanOrEqual(8 * 1024 * 1024);
  });

  it("rejects original photos above the private-bucket upload ceiling", async () => {
    await expect(transformStayImageForPublication(new Uint8Array(10 * 1024 * 1024 + 1))).rejects.toThrow();
  });

  it("rejects undecodable file content", async () => {
    await expect(transformStayImageForPublication(new Uint8Array([1, 2, 3]))).rejects.toThrow();
  });
});
