import { describe, expect, it } from "vitest";
import { isProtectedWorkspacePath } from "./lib/supabase/proxy-client";

describe("protected workspace path boundary", () => {
  it.each([
    ["/workspace", true],
    ["/workspace/bookings", true],
    ["/workspace/", true],
    ["/workspaces", false],
    ["/workspace-settings", false],
    ["/mfa", false],
  ])("classifies %s as protected=%s", (pathname, expected) => {
    expect(isProtectedWorkspacePath(pathname)).toBe(expected);
  });
});
