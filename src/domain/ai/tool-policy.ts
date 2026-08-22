export type AgentKind = "sales" | "booking" | "finance" | "manager" | "copilot" | "data_entry";

export type MembershipRole =
  | "owner"
  | "manager"
  | "sales_agent"
  | "operations"
  | "accountant"
  | "viewer";

export type AgentExecutionContext = Readonly<{
  agent: AgentKind;
  organizationId: string;
  membershipId: string;
  role: MembershipRole;
}>;

type AgentToolEffect = "read" | "proposal";

export type AgentTool = Readonly<{
  name: "search_properties_v1" | "check_availability_v1" | "read_copilot_context_v1";
  effect: AgentToolEffect;
  modelArgumentNames: readonly string[];
}>;

type AgentToolGrant = Readonly<{
  agent: AgentKind;
  roles: readonly MembershipRole[];
}>;

type AgentToolRegistryEntry = AgentTool &
  Readonly<{
    grants: readonly AgentToolGrant[];
  }>;

const TOOL_REGISTRY: readonly AgentToolRegistryEntry[] = [
  {
    name: "read_copilot_context_v1",
    effect: "read",
    grants: [{ agent: "copilot", roles: ["owner", "manager", "sales_agent", "operations"] }],
    modelArgumentNames: [],
  },
  {
    name: "search_properties_v1",
    effect: "read",
    grants: [
      { agent: "sales", roles: ["owner", "manager", "sales_agent"] },
      { agent: "booking", roles: ["owner", "manager", "sales_agent", "operations"] },
      { agent: "manager", roles: ["owner", "manager"] },
    ],
    modelArgumentNames: ["query", "limit"],
  },
  {
    name: "check_availability_v1",
    effect: "read",
    grants: [
      { agent: "sales", roles: ["owner", "manager", "sales_agent"] },
      { agent: "booking", roles: ["owner", "manager", "sales_agent", "operations"] },
      { agent: "manager", roles: ["owner", "manager"] },
    ],
    modelArgumentNames: ["propertyId", "startDate", "endDate"],
  },
];

export function resolveAllowedAgentTools(
  context: AgentExecutionContext,
): readonly AgentTool[] {
  return TOOL_REGISTRY.filter(
    (tool) =>
      tool.grants.some(
        (grant) => grant.agent === context.agent && grant.roles.includes(context.role),
      ),
  );
}

export function assertAgentToolAllowed(
  context: AgentExecutionContext,
  toolName: string,
): AgentTool {
  const tool = resolveAllowedAgentTools(context).find((candidate) => candidate.name === toolName);

  if (!tool) {
    throw new Error("AI tool is not allowed");
  }

  return tool;
}
