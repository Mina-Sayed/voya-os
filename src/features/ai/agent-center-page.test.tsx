import { fireEvent, render, screen } from "@testing-library/react";
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

test("renders a structured Gemini proposal and can hide its card", () => {
  render(
    <AgentCenterPage
      agents={[]}
      requestRun={requestRun}
      runs={[{
        id: "run-gemini",
        agentKind: "copilot",
        agentVersion: "registry-v1",
        status: "succeeded",
        purpose: "اقتراح متابعة",
        modelName: "gemini-3.5-flash",
        promptVersion: "proposal-v1",
        initiatedByMembershipId: "member-a",
        createdAt: "2026-08-01T10:00:00Z",
        startedAt: "2026-08-01T10:00:01Z",
        finishedAt: "2026-08-01T10:00:03Z",
        errorCode: null,
        resultSummary: {
          provider: "gemini",
          model: "gemini-3.5-flash",
          output: JSON.stringify({ summary: "ملخص منظم", suggestions: ["اقتراح أول"], risks: ["مخاطرة"] }),
        },
        toolCalls: [],
      }]}
    />,
  );

  expect(screen.getByText("ملخص منظم")).toBeInTheDocument();
  expect(screen.getByText("اقتراح أول")).toBeInTheDocument();
  expect(screen.getByText("مخاطرة")).toBeInTheDocument();
  expect(screen.queryByText(/"summary"/u)).not.toBeInTheDocument();

  fireEvent.click(screen.getByRole("button", { name: /إخفاء رد اقتراح متابعة/u }));
  expect(screen.queryByRole("heading", { name: "اقتراح متابعة" })).not.toBeInTheDocument();
  expect(screen.getByRole("button", { name: /إظهار النتائج المخفية/u })).toBeInTheDocument();
});
