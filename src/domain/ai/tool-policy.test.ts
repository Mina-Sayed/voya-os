import { expect, test } from "vitest";
import {
  assertAgentToolAllowed,
  resolveAllowedAgentTools,
  type AgentExecutionContext,
} from "./tool-policy";

const bookingSalesContext: AgentExecutionContext = {
  agent: "booking",
  organizationId: "organization-voya",
  membershipId: "membership-sales",
  role: "sales_agent",
};

test("returns only advisory read tools for a booking agent with a sales membership", () => {
  expect(resolveAllowedAgentTools(bookingSalesContext)).toEqual([
    expect.objectContaining({
      effect: "read",
      name: "search_properties_v1",
    }),
    expect.objectContaining({
      effect: "read",
      name: "check_availability_v1",
    }),
  ]);
});

test("fails closed when a finance agent requests a finance proposal tool", () => {
  const financeContext: AgentExecutionContext = {
    agent: "finance",
    organizationId: "organization-voya",
    membershipId: "membership-accountant",
    role: "accountant",
  };

  expect(() => assertAgentToolAllowed(financeContext, "create_finance_proposal_v1")).toThrow(
    "AI tool is not allowed",
  );
});

test("returns the exact permitted descriptor for an allowed tool", () => {
  expect(assertAgentToolAllowed(bookingSalesContext, "check_availability_v1")).toEqual(
    expect.objectContaining({
      effect: "read",
      modelArgumentNames: ["propertyId", "startDate", "endDate"],
      name: "check_availability_v1",
    }),
  );
});

test("does not expose trusted organization or membership values as model arguments", () => {
  const tools = resolveAllowedAgentTools(bookingSalesContext);

  expect(tools.flatMap((tool) => tool.modelArgumentNames)).not.toContain("organizationId");
  expect(tools.flatMap((tool) => tool.modelArgumentNames)).not.toContain("membershipId");
});

test("keeps agent-specific role grants separate instead of combining their roles", () => {
  const operationsManagerContext: AgentExecutionContext = {
    agent: "manager",
    organizationId: "organization-voya",
    membershipId: "membership-operations",
    role: "operations",
  };
  const viewerManagerContext: AgentExecutionContext = {
    ...operationsManagerContext,
    membershipId: "membership-viewer",
    role: "viewer",
  };

  expect(resolveAllowedAgentTools(operationsManagerContext)).toEqual([]);
  expect(resolveAllowedAgentTools(viewerManagerContext)).toEqual([]);
});

test("allows the copilot context read without exposing mutation tools", () => {
  const context: AgentExecutionContext = {
    agent: "copilot",
    organizationId: "organization-voya",
    membershipId: "membership-sales",
    role: "sales_agent",
  };

  expect(resolveAllowedAgentTools(context)).toEqual([
    expect.objectContaining({ name: "read_copilot_context_v1", effect: "read" }),
  ]);
  expect(() => assertAgentToolAllowed(context, "create_booking_v1")).toThrow("AI tool is not allowed");
});

test("keeps finance disabled and never offers a booking command to an agent", () => {
  const financeContext: AgentExecutionContext = {
    agent: "finance",
    organizationId: "organization-voya",
    membershipId: "membership-accountant",
    role: "accountant",
  };

  expect(resolveAllowedAgentTools(financeContext)).toEqual([]);
  expect(resolveAllowedAgentTools(bookingSalesContext).map((tool) => tool.name)).not.toContain(
    "create_booking_draft",
  );
});
