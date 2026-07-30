import { AuthSessionMissingError } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import {
  isMissingSupabasePublicConfiguration,
  isSignedOutUserResult,
  resolveWorkspaceContext,
  WorkspaceDependencyError,
} from "./workspace-context";

const organizationA = {
  id: "membership-a",
  organizationId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  organizationName: "مؤسسة ألف",
  role: "owner",
  status: "active" as const,
};
const organizationB = {
  ...organizationA,
  id: "membership-b",
  organizationId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  organizationName: "مؤسسة باء",
  role: "manager",
};

describe("resolveWorkspaceContext", () => {
  it("reports pending when there is no active membership", () => {
    expect(resolveWorkspaceContext([], null)).toEqual({ state: "pending" });
  });

  it("selects the only active membership", () => {
    expect(resolveWorkspaceContext([organizationA], null)).toEqual({ state: "ready", membership: organizationA });
  });

  it("selects a validated organization among several memberships", () => {
    expect(resolveWorkspaceContext([organizationA, organizationB], organizationB.organizationId)).toEqual({ state: "ready", membership: organizationB });
  });

  it("requires an explicit selection for several active memberships", () => {
    expect(resolveWorkspaceContext([organizationA, organizationB], null)).toEqual({
      state: "selection_required",
      memberships: [organizationA, organizationB],
    });
  });

  it("rejects a stale or foreign selected organization", () => {
    expect(resolveWorkspaceContext([organizationA, organizationB], "cccccccc-cccc-4ccc-8ccc-cccccccccccc")).toEqual({
      state: "selection_required",
      memberships: [organizationA, organizationB],
    });
  });
});

describe("WorkspaceDependencyError", () => {
  it("keeps a safe code without retaining a raw dependency message", () => {
    const error = new WorkspaceDependencyError("membership_query_failed", new Error("secret database detail"));
    expect(error.code).toBe("membership_query_failed");
    expect(error.message).not.toContain("secret database detail");
    expect(JSON.stringify(error)).not.toContain("secret database detail");
  });
});

describe("isSignedOutUserResult", () => {
  it("treats Supabase's missing-session response as signed out", () => {
    expect(isSignedOutUserResult(null, new AuthSessionMissingError())).toBe(true);
  });

  it("does not conceal an unavailable auth dependency as signed out", () => {
    expect(isSignedOutUserResult(null, new Error("provider unavailable"))).toBe(false);
  });
});

describe("isMissingSupabasePublicConfiguration", () => {
  it("identifies only an incomplete public Supabase configuration", () => {
    expect(isMissingSupabasePublicConfiguration(
      new SupabaseConfigurationError("Supabase public configuration is incomplete."),
    )).toBe(true);
    expect(isMissingSupabasePublicConfiguration(
      new SupabaseConfigurationError("Supabase project URL is invalid."),
    )).toBe(false);
  });
});

describe("reportWorkspaceActionFailure", () => {
  it("preserves the command request ID when reporting a failure", async () => {
    const { reportWorkspaceActionFailure } = await import("./workspace-context");
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const requestId = "11111111-1111-4111-8111-111111111111";

    reportWorkspaceActionFailure("workspace.client.create", new Error("token=secret"), requestId);

    expect(write).toHaveBeenCalledWith(expect.stringContaining(`"request_id":"${requestId}"`));
    expect(write.mock.calls.flat().join(" ")).not.toContain("secret");
  });
});
