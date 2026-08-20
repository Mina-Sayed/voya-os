import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { AgentCenterPage } from "./agent-center-page";

const requestRun = vi.fn(async () => ({ status: "success" as const, message: "تم" }));

test("renders governed agent registry and no automatic execution claim", () => {
  render(
    <AgentCenterPage
      agents={[
        { kind: "copilot", label: "مساعد فُويا", description: "قراءة واقتراح", mode: "preview", roles: ["sales_agent"] },
        { kind: "sales", label: "مساعد المبيعات", description: "قراءة واقتراح", mode: "preview", roles: ["sales_agent"] },
        { kind: "finance", label: "مساعد المالية", description: "غير مفعّل", mode: "disabled", roles: ["accountant"] },
      ]}
      requestRun={requestRun}
      runs={[]}
    />,
  );

  expect(screen.getByRole("heading", { name: "مركز الذكاء" })).toBeInTheDocument();
  expect(screen.getByRole("heading", { name: "مساعد فُويا" })).toBeInTheDocument();
  expect(screen.getByRole("heading", { name: "مساعد المبيعات" })).toBeInTheDocument();
  expect(screen.getByRole("heading", { name: "مساعد المالية" })).toBeInTheDocument();
  expect(screen.getAllByText("0", { selector: "p" }).length).toBeGreaterThanOrEqual(1);
  expect(screen.getByText(/لا يوجد تنفيذ تلقائي|تنفيذ تلقائي/)).toBeInTheDocument();
});

test("renders a sanitized run and policy decision without exposing raw summaries", () => {
  render(
    <AgentCenterPage
      agents={[]}
      requestRun={requestRun}
      runs={[{ id: "run-a", agentKind: "sales", agentVersion: "registry-v1", status: "succeeded", purpose: "اقتراح متابعة", modelName: "unconfigured", promptVersion: "unconfigured", initiatedByMembershipId: "member-a", createdAt: "2026-08-01T10:00:00Z", startedAt: null, finishedAt: null, errorCode: null, resultSummary: null, toolCalls: [{ id: "tool-a", toolName: "search_properties_v1", toolVersion: "registry-v1", effect: "read", policyDecision: "allowed", status: "succeeded", createdAt: "2026-08-01T10:01:00Z" }] }]}
    />,
  );

  expect(screen.getByRole("heading", { name: "اقتراح متابعة" })).toBeInTheDocument();
  expect(screen.getByText("search_properties_v1")).toBeInTheDocument();
  expect(screen.getByText("مسموح")).toBeInTheDocument();
  expect(screen.queryByText(/request_summary|response_summary/)).not.toBeInTheDocument();
});
