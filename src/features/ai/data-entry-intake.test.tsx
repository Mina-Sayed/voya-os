import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import { DataEntryIntake, type DataEntryDraftSummary } from "./data-entry-intake";

const draft: DataEntryDraftSummary = {
  id: "draft-1",
  status: "collecting",
  sourceKind: "text",
  version: 1,
  inputCount: 0,
  createdAt: "2026-08-22T00:00:00.000Z",
};

const actions = {
  create: vi.fn(async () => ({ status: "idle" as const, message: "" })),
  submit: vi.fn(async () => ({ status: "idle" as const, message: "" })),
};

describe("DataEntryIntake", () => {
  test("explains the human-confirmed boundary and offers text intake", () => {
    render(<DataEntryIntake createDraft={actions.create} drafts={[]} submitDraft={actions.submit} />);

    expect(screen.getByRole("heading", { name: "إدخال بيانات بمساعدة Gemini" })).toBeVisible();
    expect(screen.getByText(/لن يُحفظ أي عميل أو عقار قبل مراجعتك وتأكيدك/)).toBeVisible();
    expect(screen.getByRole("textbox", { name: "بيانات العملاء أو العقارات" })).toBeVisible();
    expect(screen.getByRole("button", { name: "تجهيز مسودة" })).toBeVisible();
  });

  test("shows an existing draft as a resumable review state", () => {
    render(<DataEntryIntake createDraft={actions.create} drafts={[draft, { ...draft, id: "draft-2", status: "ready_for_review", inputCount: 2 }]} submitDraft={actions.submit} />);

    expect(screen.getAllByText("جاهزة للمراجعة").length).toBeGreaterThan(0);
    const continueButton = screen.getByRole("button", { name: "متابعة المسودة" });
    expect(continueButton).toBeVisible();
    fireEvent.click(continueButton);
    expect(screen.getByText("صورتان مرفوعتان")).toBeVisible();
  });

  test("rejects a file larger than the intake limit before making a network call", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    render(<DataEntryIntake createDraft={actions.create} drafts={[draft]} submitDraft={actions.submit} />);
    const file = new File([new Uint8Array(10 * 1024 * 1024 + 1)], "large.png", { type: "image/png" });
    const input = screen.getByLabelText("رفع صور مرجعية");

    fireEvent.change(input, { target: { files: [file] } });

    await waitFor(() => expect(screen.getByText("بعض الملفات أكبر من الحد المسموح (10MB). لم يتم رفعها.")).toBeVisible());
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
  });
});
