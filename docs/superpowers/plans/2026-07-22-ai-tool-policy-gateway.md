# AI Tool Policy Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide a pure, server-owned policy layer that resolves the small, safe tool allowlist for each initial Voya OS AI agent before a model/provider integration exists.

**Architecture:** A domain module owns agent kinds, tool descriptors, trusted execution context, and fail-closed authorization. It returns only descriptors that can later be translated to Responses API function definitions; it contains no provider client, database client, route handler, financial mutation, or booking mutation. Trusted organization and membership values remain required context but never become model-controlled tool parameters.

**Tech Stack:** TypeScript, Vitest, existing Voya OS domain conventions. Future provider integration will use OpenAI Responses API custom function tools with strict schemas.

## Global Constraints

- The policy must fail closed for an unknown agent, role, or tool.
- No allowed tool may write a booking or financial source-of-record, approve an action, or receive organization/member identifiers from model arguments.
- The finance agent remains tool-disabled until finance records and rules are approved.
- The module must be pure and deterministic; it does not make database, network, OpenAI, filesystem, or browser calls.
- Existing uncommitted user files remain untouched and are not staged.

---

### Task 1: Define and prove the fail-closed public contract

**Files:**
- Create: `src/domain/ai/tool-policy.test.ts`
- Create: `src/domain/ai/tool-policy.ts`

**Interfaces:**
- Produces: `AgentKind`, `AgentExecutionContext`, `AgentTool`, `resolveAllowedAgentTools(context)`, and `assertAgentToolAllowed(context, toolName)`.
- Consumes: the current six membership role strings and the AI constraints in `docs/AI_AGENTS.md`.

- [x] **Step 1: Write the failing tests**

```ts
expect(resolveAllowedAgentTools({ agent: "booking", role: "sales_agent" }))
  .toEqual([expect.objectContaining({ name: "search_properties_v1", effect: "read" })]);
expect(() => assertAgentToolAllowed(financeContext, "create_finance_proposal_v1"))
  .toThrow("AI tool is not allowed");
```

- [x] **Step 2: Run the focused test to verify it fails**

Run: `npm run test -- src/domain/ai/tool-policy.test.ts`

Expected: FAIL because `src/domain/ai/tool-policy.ts` does not exist.

- [x] **Step 3: Implement the minimal policy module**

```ts
export function resolveAllowedAgentTools(context: AgentExecutionContext): readonly AgentTool[] {
  return TOOL_REGISTRY.filter((tool) => tool.agents.includes(context.agent) && tool.roles.includes(context.role));
}

export function assertAgentToolAllowed(context: AgentExecutionContext, toolName: string): AgentTool {
  const tool = resolveAllowedAgentTools(context).find((candidate) => candidate.name === toolName);
  if (!tool) throw new Error("AI tool is not allowed");
  return tool;
}
```

Define only read/advisory/proposal descriptors. Do not add booking, finance, approval, SQL, HTTP, shell, or export mutation descriptors.

- [x] **Step 4: Run focused tests to verify they pass**

Run: `npm run test -- src/domain/ai/tool-policy.test.ts`

Expected: PASS.

### Task 2: Cover privilege and data-boundary edge cases

**Files:**
- Modify: `src/domain/ai/tool-policy.test.ts`
- Modify: `src/domain/ai/tool-policy.ts`

**Interfaces:**
- Consumes: the Task 1 contract.
- Produces: exhaustive role/agent allowlist coverage and immutable public results.

- [x] **Step 1: Write failing edge-case tests**

```ts
expect(resolveAllowedAgentTools({ agent: "manager", role: "viewer" })).toEqual([]);
expect(resolveAllowedAgentTools({ agent: "finance", role: "accountant" })).toEqual([]);
expect(resolveAllowedAgentTools(bookingContext).map((tool) => tool.name)).not.toContain("create_booking_draft");
```

- [x] **Step 2: Run focused test to verify it fails**

Run: `npm run test -- src/domain/ai/tool-policy.test.ts`

Expected: FAIL until the policy has the intended restrictive role mapping.

- [x] **Step 3: Refine the minimal allowlist**

Keep sales limited to sales/manager/owner, booking to operations/sales/manager/owner, and manager to manager/owner. Permit only property search and advisory availability reads initially. Reject all other role/agent combinations.

- [x] **Step 4: Run focused tests to verify they pass**

Run: `npm run test -- src/domain/ai/tool-policy.test.ts`

Expected: PASS.

### Task 3: Record review evidence and verify the repository

**Files:**
- Create: `docs/SECURITY_REVIEW_AI_TOOL_POLICY_GATEWAY.md`

- [x] **Step 1: Document the threat review**

Record the trust boundary, denied tool classes, residual risks, and launch blockers: no provider adapter, no run audit schema, no eval harness, and no finance/approval policy.

- [x] **Step 2: Run repository gates**

Run:

```bash
npm run test:coverage
npm run test:db
npm run test:e2e
npm run lint
npm run build
npm audit --omit=dev --audit-level=high
git diff --check
```

Expected: all application/DB/browser/build checks pass and the production dependency audit has no high or critical vulnerabilities.

- [ ] **Step 3: Commit only owned files**

```bash
git add src/domain/ai/tool-policy.ts src/domain/ai/tool-policy.test.ts docs/SECURITY_REVIEW_AI_TOOL_POLICY_GATEWAY.md docs/superpowers/plans/2026-07-22-ai-tool-policy-gateway.md
git commit -m "feat: add fail-closed AI tool policy gateway"
```

Expected: no pre-existing `README.md`, `.codex/`, or unrelated untracked documentation is staged.
