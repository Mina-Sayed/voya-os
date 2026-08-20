import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { SystemHealthPage } from "./system-health-page";

const release = { version: "v1", commit: "abc123", environment: "local" } as const;

describe("SystemHealthPage", () => {
  it("renders the release identity and operational aggregates without secrets", () => {
    render(<SystemHealthPage release={release} health={{ databaseStatus: "ok", lastWorkerRunAt: "2026-08-17T08:00:00.000Z", lastWorkerStatus: "completed", pendingOutboxCount: 2, oldestDueEventAt: "2026-08-17T07:50:00.000Z", deadLetterCount: 0, emailFailureCount: 1, whatsappFailureCount: 0, aiFailureCount: 0 }} />);
    expect(screen.getByRole("heading", { name: "صحة النظام" })).toBeInTheDocument();
    expect(screen.getByText("abc123")).toBeInTheDocument();
    expect(screen.getByText("Database Status")).toBeInTheDocument();
    expect(screen.getByText("Pending Outbox")).toBeInTheDocument();
    expect(screen.getByText("Email Failures")).toBeInTheDocument();
    expect(screen.queryByText(/service_role|secret|token/i)).not.toBeInTheDocument();
  });

  it("shows an explicit degraded state", () => {
    render(<SystemHealthPage release={release} health={{ databaseStatus: "not_ready", lastWorkerRunAt: null, lastWorkerStatus: "failed", pendingOutboxCount: 0, oldestDueEventAt: null, deadLetterCount: 1, emailFailureCount: 0, whatsappFailureCount: 2, aiFailureCount: 3 }} />);
    expect(screen.getByText("قاعدة البيانات غير جاهزة")).toBeInTheDocument();
    expect(screen.getByText("فشل")).toBeInTheDocument();
    expect(screen.getByText("Dead Letters")).toBeInTheDocument();
    expect(screen.getByText("WhatsApp Failures")).toBeInTheDocument();
  });
});
