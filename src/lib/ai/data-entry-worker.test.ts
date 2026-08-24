import { describe, expect, test } from "vitest";
import { bytesToBase64, validateDataEntryWorkerInputs } from "./data-entry-worker";

describe("data-entry worker input boundary", () => {
  test("encodes image bytes without leaking or changing their content", () => {
    expect(bytesToBase64(new Uint8Array([0, 1, 2, 255]))).toBe("AAEC/w==");
  });

  test("accepts bounded private image metadata", () => {
    expect(validateDataEntryWorkerInputs([
      { id: "input-1", storage_bucket: "ai-intake", storage_path: "org/draft/input.png", mime_type: "image/png", byte_size: 12 },
    ])).toEqual({
      ok: true,
      value: [{ id: "input-1", storageBucket: "ai-intake", storagePath: "org/draft/input.png", mimeType: "image/png", byteSize: 12 }],
    });
  });

  test("rejects foreign buckets, unsupported MIME, and oversized batches", () => {
    const result = validateDataEntryWorkerInputs([
      { id: "input-1", storage_bucket: "public", storage_path: "org/draft/input.png", mime_type: "image/png", byte_size: 12 },
      ...Array.from({ length: 20 }, (_, index) => ({ id: `input-${index + 2}`, storage_bucket: "ai-intake", storage_path: "org/draft/input.png", mime_type: "image/gif", byte_size: 2_000_000 })),
    ]);

    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.errors).toEqual(expect.arrayContaining(["unsupported_bucket", "unsupported_mime", "input_count_limit", "input_bytes_limit"]));
  });
});
