import { render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import { DataEntryIntake, type DataEntryDraftSummary } from "./data-entry-intake";

const actions = {
  create: vi.fn(async () => ({ status: "idle" as const, message: "" })),
  submit: vi.fn(async () => ({ status: "idle" as const, message: "" })),
};

function draft(index: number): DataEntryDraftSummary {
  return {
    id: `draft-${index}`,
    status: "collecting",
    sourceKind: "text",
    version: 1,
    inputCount: 0,
    createdAt: `2026-08-22T00:00:0${index}.000Z`,
  };
}

describe("DataEntryIntake remediation", () => {
  test("does not require source text so image-only intake is reachable", () => {
    render(<DataEntryIntake createDraft={actions.create} drafts={[]} submitDraft={actions.submit} />);

    expect(screen.getByRole("textbox", { name: "بيانات العملاء أو العقارات" })).not.toBeRequired();
  });

  test("keeps every draft returned by the bounded query reachable", () => {
    render(<DataEntryIntake createDraft={actions.create} drafts={Array.from({ length: 6 }, (_, index) => draft(index + 1))} submitDraft={actions.submit} />);

    expect(screen.getAllByRole("button", { name: "متابعة المسودة" })).toHaveLength(5);
  });
});
