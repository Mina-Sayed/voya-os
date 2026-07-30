import { AuthSessionMissingError } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

const runtime = vi.hoisted(() => ({
  connection: vi.fn(),
  cookies: vi.fn(),
  createServerSupabaseClient: vi.fn(),
}));

vi.mock("next/server", () => ({
  connection: runtime.connection,
}));

vi.mock("next/headers", () => ({
  cookies: runtime.cookies,
}));

vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: runtime.createServerSupabaseClient,
}));

import {
  isMissingSupabasePublicConfiguration,
  isSignedOutUserResult,
  loadActiveWorkspaceMemberships,
  loadActionWorkspaceMembership,
  loadWorkspaceContext,
  resolveWorkspaceContext,
  throwWorkspaceOperationError,
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

function authenticatedClient({
  user = { id: "user-a" },
  userError = null,
  membershipResult = { data: [], error: null },
}: {
  user?: { id: string } | null;
  userError?: unknown;
  membershipResult?: { data: unknown; error: unknown };
}) {
  const order = vi.fn().mockResolvedValue(membershipResult);
  const byStatus = vi.fn().mockReturnValue({ order });
  const byUser = vi.fn().mockReturnValue({ eq: byStatus });
  return {
    auth: { getUser: vi.fn().mockResolvedValue({ data: { user }, error: userError }) },
    from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
  };
}

afterEach(() => {
  vi.clearAllMocks();
  runtime.connection.mockResolvedValue(undefined);
  runtime.cookies.mockResolvedValue({ get: vi.fn().mockReturnValue(undefined) });
});

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

describe("loadActiveWorkspaceMemberships", () => {
  it("maps the active memberships returned for an authenticated user", async () => {
    runtime.createServerSupabaseClient.mockResolvedValue(authenticatedClient({
      membershipResult: {
        data: [
          {
            id: "membership-a",
            organization_id: organizationA.organizationId,
            role: "owner",
            status: "active",
            organizations: [{ name: " مؤسسة ألف " }],
          },
          {
            id: "membership-b",
            organization_id: organizationB.organizationId,
            role: "manager",
            status: "active",
            organizations: null,
          },
        ],
        error: null,
      },
    }));

    await expect(loadActiveWorkspaceMemberships()).resolves.toEqual({
      state: "authenticated",
      memberships: [
        { ...organizationA, organizationName: "مؤسسة ألف" },
        { ...organizationB, organizationName: organizationB.organizationId },
      ],
    });
  });

  it("returns signed out for Supabase's expected missing-session response", async () => {
    runtime.createServerSupabaseClient.mockResolvedValue(authenticatedClient({
      user: null,
      userError: new AuthSessionMissingError(),
    }));
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await expect(loadActiveWorkspaceMemberships()).resolves.toEqual({ state: "signed_out" });

    expect(write).not.toHaveBeenCalled();
  });

  it("keeps an empty successful membership response distinct from a query failure", async () => {
    runtime.createServerSupabaseClient.mockResolvedValue(authenticatedClient({
      membershipResult: { data: null, error: null },
    }));

    await expect(loadActiveWorkspaceMemberships()).resolves.toEqual({ state: "authenticated", memberships: [] });
  });

  it("does not treat an authentication provider failure as a signed-out user", async () => {
    runtime.createServerSupabaseClient.mockResolvedValue(authenticatedClient({
      user: null,
      userError: new Error("provider token=secret"),
    }));
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await expect(loadActiveWorkspaceMemberships()).rejects.toMatchObject({ code: "auth_user_failed" });

    expect(write.mock.calls.flat().join(" ")).not.toContain("secret");
  });

  it("fails closed when the active-membership query is unavailable", async () => {
    runtime.createServerSupabaseClient.mockResolvedValue(authenticatedClient({
      membershipResult: { data: null, error: new Error("database password=secret") },
    }));
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await expect(loadActiveWorkspaceMemberships()).rejects.toMatchObject({ code: "membership_query_failed" });

    expect(write.mock.calls.flat().join(" ")).not.toContain("secret");
  });

  it("shows selection when the saved organization is not among active memberships", async () => {
    runtime.createServerSupabaseClient.mockResolvedValue(authenticatedClient({
      membershipResult: {
        data: [
          { id: organizationA.id, organization_id: organizationA.organizationId, role: organizationA.role, status: "active", organizations: { name: organizationA.organizationName } },
          { id: organizationB.id, organization_id: organizationB.organizationId, role: organizationB.role, status: "active", organizations: { name: organizationB.organizationName } },
        ],
        error: null,
      },
    }));
    runtime.cookies.mockResolvedValue({ get: vi.fn().mockReturnValue({ value: "stale-organization" }) });

    await expect(loadWorkspaceContext()).resolves.toEqual({
      state: "selection_required",
      memberships: [organizationA, organizationB],
    });
  });

  it("does not read an organization cookie after resolving a signed-out context", async () => {
    runtime.createServerSupabaseClient.mockResolvedValue(authenticatedClient({ user: null }));
    const cookieStore = { get: vi.fn() };
    runtime.cookies.mockResolvedValue(cookieStore);

    await expect(loadWorkspaceContext()).resolves.toEqual({ state: "signed_out" });

    expect(cookieStore.get).not.toHaveBeenCalled();
  });

  it("returns the selected membership for server-owned actions", async () => {
    runtime.createServerSupabaseClient.mockResolvedValue(authenticatedClient({
      membershipResult: {
        data: [{ id: organizationA.id, organization_id: organizationA.organizationId, role: organizationA.role, status: "active", organizations: { name: organizationA.organizationName } }],
        error: null,
      },
    }));

    await expect(loadActionWorkspaceMembership()).resolves.toEqual(organizationA);
  });

  it("denies an action membership when organization selection is required", async () => {
    runtime.createServerSupabaseClient.mockResolvedValue(authenticatedClient({
      membershipResult: {
        data: [
          { id: organizationA.id, organization_id: organizationA.organizationId, role: organizationA.role, status: "active", organizations: { name: organizationA.organizationName } },
          { id: organizationB.id, organization_id: organizationB.organizationId, role: organizationB.role, status: "active", organizations: { name: organizationB.organizationName } },
        ],
        error: null,
      },
    }));

    await expect(loadActionWorkspaceMembership()).resolves.toBeNull();
  });

  it("treats missing public Supabase configuration as signed out", async () => {
    runtime.createServerSupabaseClient.mockRejectedValue(
      new SupabaseConfigurationError("Supabase public configuration is incomplete."),
    );
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await expect(loadActiveWorkspaceMemberships()).resolves.toEqual({ state: "signed_out" });

    expect(write).toHaveBeenCalledWith(expect.stringContaining('"code":"auth_config_missing"'));
  });

  it("does not expose a server-client dependency failure as a signed-out state", async () => {
    runtime.createServerSupabaseClient.mockRejectedValue(new Error("client password=secret"));
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await expect(loadActiveWorkspaceMemberships()).rejects.toMatchObject({ code: "auth_client_failed" });

    expect(write).toHaveBeenCalledWith(expect.stringContaining('"code":"auth_client_failed"'));
    expect(write.mock.calls.flat().join(" ")).not.toContain("secret");
  });
});

describe("throwWorkspaceOperationError", () => {
  it("logs safe metadata and keeps the dependency cause out of the returned error", () => {
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    expect(() => throwWorkspaceOperationError("workspace.memberships", new Error("password=secret")))
      .toThrow(WorkspaceDependencyError);

    expect(write).toHaveBeenCalledWith(expect.stringContaining('"operation":"workspace.memberships"'));
    expect(write.mock.calls.flat().join(" ")).not.toContain("secret");
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
