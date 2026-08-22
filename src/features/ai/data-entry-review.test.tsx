import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import { DataEntryReview, type DataEntryDraftReview } from "./data-entry-review";

const review: DataEntryDraftReview = {
  id: "draft-1",
  status: "ready_for_review",
  version: 3,
  sourceText: "أحمد، شقة في مصر الجديدة",
  payload: {
    clients: [{ displayName: null, phone: null, whatsapp: null, email: null, nationality: null, preferredLanguage: null, notes: null, sourceLeadId: null, confidence: "low", missingRequired: ["display_name"] }],
    properties: [{ code: null, name: "شقة مصر الجديدة", timezone: "Africa/Cairo", address: "شارع الحجاز", city: "القاهرة الجديدة", unitLabel: null, bedrooms: null, maxGuests: null, operationalNotes: null, imageInputIds: [], confidence: "medium", missingRequired: ["code"] }],
    unresolved: [{ value: "150 متر", reason: "لا يوجد حقل مساحة" }],
    warnings: [],
  },
  inputs: [{ id: "input-1", mimeType: "image/png", byteSize: 1200, status: "active", mappedPropertyId: null }],
};

const actions = {
  confirm: vi.fn(async () => ({ status: "idle" as const, message: "" })),
  reject: vi.fn(async () => ({ status: "idle" as const, message: "" })),
};

describe("DataEntryReview", () => {
  test("shows model provenance, unresolved facts, and blocks incomplete confirmation", () => {
    render(<DataEntryReview confirmDraft={actions.confirm} rejectDraft={actions.reject} review={review} />);

    expect(screen.getByRole("heading", { name: "مراجعة مسودة الإدخال" })).toBeVisible();
    expect(screen.getByText("150 متر")).toBeVisible();
    expect(screen.getByText("لم يتم الحفظ بعد؛ هذه مسودة قابلة للتعديل.")).toBeVisible();
    expect(screen.getByRole("button", { name: "تأكيد وحفظ" })).toBeDisabled();
  });

  test("enables confirmation only after required fields are completed", () => {
    render(<DataEntryReview confirmDraft={actions.confirm} rejectDraft={actions.reject} review={review} />);

    fireEvent.change(screen.getByRole("textbox", { name: "اسم العميل 0" }), { target: { value: "أحمد" } });
    fireEvent.change(screen.getByRole("textbox", { name: "كود العقار 0" }), { target: { value: "HEG-001" } });

    expect(screen.getByRole("button", { name: "تأكيد وحفظ" })).not.toBeDisabled();
  });

  test("allows mapping a private input to a property without exposing a public URL", () => {
    render(<DataEntryReview confirmDraft={actions.confirm} rejectDraft={actions.reject} review={review} />);

    expect(screen.getByLabelText("ربط الصورة input-1 بالعقار 0")).toBeVisible();
    expect(screen.queryByText(/https?:\/\//)).not.toBeInTheDocument();
  });
});
