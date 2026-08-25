import { render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import { DataEntryReview, type DataEntryDraftReview } from "./data-entry-review";

const baseReview: DataEntryDraftReview = {
  id: "draft-1",
  status: "ready_for_review",
  version: 3,
  sourceText: "أحمد",
  payload: {
    clients: [{
      displayName: "أحمد",
      phone: null,
      whatsapp: null,
      email: null,
      nationality: null,
      preferredLanguage: null,
      notes: null,
      sourceLeadId: null,
      confidence: "high",
      missingRequired: [],
    }],
    properties: [],
    unresolved: [],
    warnings: [],
  },
  inputs: [],
};

const actions = {
  confirm: vi.fn(async () => ({ status: "idle" as const, message: "" })),
  reject: vi.fn(async () => ({ status: "idle" as const, message: "" })),
};

describe("DataEntryReview remediation", () => {
  test("lets the operator exclude an unapplied Gemini candidate", () => {
    render(<DataEntryReview confirmDraft={actions.confirm} rejectDraft={actions.reject} review={baseReview} />);

    expect(screen.getByRole("button", { name: "استبعاد العميل 0" })).toBeVisible();
  });

  test("renders applied drafts as terminal read-only results", () => {
    render(<DataEntryReview confirmDraft={actions.confirm} rejectDraft={actions.reject} review={{ ...baseReview, status: "applied" }} />);

    expect(screen.queryByRole("button", { name: "تأكيد وحفظ" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "إلغاء المسودة وتنظيف الملفات" })).not.toBeInTheDocument();
  });
});
