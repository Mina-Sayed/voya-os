import { describe, expect, it } from "vitest";
import { resolveActiveMembership } from "./active-membership";

const activeMembership = {
  id: "membership-a",
  organizationId: "organization-a",
  role: "manager",
  status: "active",
} as const;

describe("resolveActiveMembership", () => {
  it("returns one active membership", () => {
    expect(resolveActiveMembership([activeMembership])).toEqual(activeMembership);
  });

  it("returns null when no membership exists", () => {
    expect(resolveActiveMembership([])).toBeNull();
  });

  it("returns null for a suspended membership", () => {
    expect(resolveActiveMembership([{ ...activeMembership, status: "suspended" }])).toBeNull();
  });

  it("rejects an ambiguous active organization context", () => {
    expect(resolveActiveMembership([activeMembership, { ...activeMembership, id: "membership-b", organizationId: "organization-b" }])).toBeNull();
  });
});
