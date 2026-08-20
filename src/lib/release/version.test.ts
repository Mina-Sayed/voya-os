import { expect, test } from "vitest";
import { readReleaseInfo } from "./version";

test("returns only non-secret release identity fields", () => {
  expect(readReleaseInfo({ VOYA_RELEASE_VERSION: "v1.0.0", VOYA_RELEASE_SHA: "abc123", VERCEL_ENV: "preview" })).toEqual({
    version: "v1.0.0",
    commit: "abc123",
    environment: "preview",
  });
});

test("uses honest unknown defaults when deployment metadata is absent", () => {
  expect(readReleaseInfo({})).toEqual({ version: "v1", commit: "unknown", environment: "unknown" });
});
