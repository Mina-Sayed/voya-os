import { render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import { DataEntryReview, type DataEntryDraftReview } from "./data-entry-review";

const actions = {
  confirm: vi.fn(async () => ({ status: "idle" as const, message: "" })),
  reject: vi.fn(async () => ({ status: "idle" as const, message: "" })),
};

const baseReview: DataEntryDraftReview = {
  id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  status: "ready_for_review",
  version: 4,
  sourceText: "بيانات للمراجعة",
  payload: {
    clients: [{
      displayName: "أحمد",
      phone: null,
      whatsapp: null,
      email: null,
      nationality: null,
      preferredLanguage: "ar",
      notes: null,
      sourceLeadId: null,
      confidence: "high",
      missingRequired: [],
    }],
    properties: [{
      code: "PROP-1",
      name: "شقة",
      timezone: "Africa/Cairo",
      address: null,
      city: "القاهرة",
      unitLabel: null,
      bedrooms: 2,
      maxGuests: 4,
      operationalNotes: null,
      imageInputIds: ["cccccccc-cccc-cccc-cccc-cccccccccccc"],
      confidence: "high",
      missingRequired: [],
    }],
    unresolved: [],
    warnings: [],
  },
  inputs: [{
    id: "cccccccc-cccc-cccc-cccc-cccccccccccc",
    mimeType: "image/png",
    byteSize: 2048,
    status: "active",
    mappedPropertyId: null,
  }],
  applicationResult: { clients: [], properties: [], images: [] },
};

describe("DataEntryReview recovery UX", () => {
  test("keeps a confirmed draft actionable but immutable so a stale execution lease can be reclaimed safely", () => {
    render(<DataEntryReview confirmDraft={actions.confirm} rejectDraft={actions.reject} review={{ ...baseReview, status: "confirmed" }} />);

    expect(screen.getByText(/يوجد تنفيذ تأكيد سابق/)).toBeVisible();
    expect(screen.getByRole("button", { name: "استكمال نفس التأكيد" })).toBeVisible();
    expect(screen.getByRole("textbox", { name: "اسم العميل 0" })).toBeDisabled();
    expect(screen.getByRole("checkbox", { name: /ربط الصورة .* بالعقار 0/ })).toBeDisabled();
    expect(screen.queryByText("اكتمل الحفظ")).not.toBeInTheDocument();
  });

  test("restores a previously excluded record as excluded after reload", () => {
    render(<DataEntryReview
      confirmDraft={actions.confirm}
      rejectDraft={actions.reject}
      review={{
        ...baseReview,
        status: "partially_applied",
        applicationResult: {
          clients: [{ index: 0, errorCode: "excluded_by_operator" }],
          properties: [],
          images: [],
        },
      }}
    />);

    expect(screen.getByRole("button", { name: "إعادة العميل 0" })).toBeVisible();
    expect(screen.getByText("مستبعد سابقًا")).toBeVisible();
  });

  test("shows the stored per-item failure beside the affected record", () => {
    render(<DataEntryReview
      confirmDraft={actions.confirm}
      rejectDraft={actions.reject}
      review={{
        ...baseReview,
        status: "partially_applied",
        applicationResult: {
          clients: [],
          properties: [{ index: 0, errorCode: "42501" }],
          images: [],
        },
      }}
    />);

    expect(screen.getByText("صلاحياتك الحالية لا تسمح بحفظ هذا العقار.")).toBeVisible();
  });

  test("keeps archived intake images disabled and does not request a broken preview", () => {
    render(<DataEntryReview
      confirmDraft={actions.confirm}
      rejectDraft={actions.reject}
      review={{
        ...baseReview,
        inputs: [{ ...baseReview.inputs[0], status: "archived" }],
      }}
    />);

    expect(screen.getByRole("checkbox", { name: /ربط الصورة .* بالعقار 0/ })).toBeDisabled();
    expect(screen.queryByRole("img", { name: /معاينة صورة الإدخال/ })).not.toBeInTheDocument();
  });

  test("renders an authenticated preview URL for each active intake image", () => {
    render(<DataEntryReview confirmDraft={actions.confirm} rejectDraft={actions.reject} review={baseReview} />);

    const preview = screen.getByRole("img", { name: /معاينة صورة الإدخال/ });
    expect(preview).toHaveAttribute(
      "src",
      `/api/workspace/ai/data-entry/inputs/preview?draft_id=${baseReview.id}&input_id=cccccccc-cccc-cccc-cccc-cccccccccccc`,
    );
  });
});
