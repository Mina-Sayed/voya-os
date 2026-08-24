import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import {
  DataEntryReview,
  type DataEntryDraftReview,
} from "./data-entry-review";

const review: DataEntryDraftReview = {
  id: "draft-1",
  status: "ready_for_review",
  version: 3,
  sourceText: "أحمد، شقة في مصر الجديدة",
  payload: {
    clients: [
      {
        displayName: null,
        phone: null,
        whatsapp: null,
        email: null,
        nationality: null,
        preferredLanguage: null,
        notes: null,
        sourceLeadId: null,
        confidence: "low",
        missingRequired: ["display_name"],
      },
    ],
    properties: [
      {
        code: null,
        name: "شقة مصر الجديدة",
        timezone: "Africa/Cairo",
        address: "شارع الحجاز",
        city: "القاهرة الجديدة",
        unitLabel: null,
        bedrooms: null,
        maxGuests: null,
        operationalNotes: null,
        imageInputIds: [],
        confidence: "medium",
        missingRequired: ["code"],
      },
    ],
    unresolved: [{ value: "150 متر", reason: "لا يوجد حقل مساحة" }],
    warnings: [],
  },
  inputs: [
    {
      id: "input-1",
      mimeType: "image/png",
      byteSize: 1200,
      status: "active",
      mappedPropertyId: null,
    },
  ],
};

const actions = {
  confirm: vi.fn(async () => ({ status: "idle" as const, message: "" })),
  reject: vi.fn(async () => ({ status: "idle" as const, message: "" })),
};

describe("DataEntryReview", () => {
  test("shows model provenance, unresolved facts, and blocks incomplete confirmation", () => {
    render(
      <DataEntryReview
        confirmDraft={actions.confirm}
        rejectDraft={actions.reject}
        review={review}
      />,
    );

    expect(
      screen.getByRole("heading", { name: "مراجعة مسودة الإدخال" }),
    ).toBeVisible();
    expect(screen.getByText("150 متر")).toBeVisible();
    expect(
      screen.getByText("لم يتم الحفظ بعد؛ هذه مسودة قابلة للتعديل."),
    ).toBeVisible();
    expect(screen.getByRole("button", { name: "تأكيد وحفظ" })).toBeDisabled();
  });

  test("enables confirmation only after required fields are completed", () => {
    render(
      <DataEntryReview
        confirmDraft={actions.confirm}
        rejectDraft={actions.reject}
        review={review}
      />,
    );

    fireEvent.change(screen.getByRole("textbox", { name: "اسم العميل 0" }), {
      target: { value: "أحمد" },
    });
    fireEvent.change(screen.getByRole("textbox", { name: "كود العقار 0" }), {
      target: { value: "HEG-001" },
    });

    expect(
      screen.getByRole("button", { name: "تأكيد وحفظ" }),
    ).not.toBeDisabled();
  });

  test("allows mapping a private input to a property without exposing a public URL", () => {
    render(
      <DataEntryReview
        confirmDraft={actions.confirm}
        rejectDraft={actions.reject}
        review={review}
      />,
    );

    expect(screen.getByLabelText("ربط الصورة input-1 بالعقار 0")).toBeVisible();
    expect(screen.queryByText(/https?:\/\//)).not.toBeInTheDocument();
  });

  test("exposes every source-record field before confirmation", () => {
    const completeReview: DataEntryDraftReview = {
      ...review,
      payload: {
        ...review.payload,
        clients: [
          {
            ...review.payload.clients[0],
            whatsapp: "+201111111111",
            preferredLanguage: "ar",
            notes: "عميل مهم",
            sourceLeadId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          },
        ],
        properties: [
          {
            ...review.payload.properties[0],
            unitLabel: "12B",
            bedrooms: 3,
            maxGuests: 6,
            operationalNotes: "تسليم المفتاح لدى الأمن",
          },
        ],
        warnings: ["راجع رقم الهاتف"],
      },
    };
    render(
      <DataEntryReview
        confirmDraft={actions.confirm}
        rejectDraft={actions.reject}
        review={completeReview}
      />,
    );

    expect(
      screen.getByRole("textbox", { name: "واتساب العميل 0" }),
    ).toHaveValue("+201111111111");
    expect(
      screen.getByRole("textbox", { name: "اللغة المفضلة للعميل 0" }),
    ).toHaveValue("ar");
    expect(
      screen.getByRole("textbox", { name: "معرّف العميل المحتمل 0" }),
    ).toHaveValue("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    expect(
      screen.getByRole("textbox", { name: "ملاحظات العميل 0" }),
    ).toHaveValue("عميل مهم");
    expect(
      screen.getByRole("textbox", { name: "رقم أو اسم وحدة العقار 0" }),
    ).toHaveValue("12B");
    expect(
      screen.getByRole("spinbutton", { name: "عدد غرف نوم العقار 0" }),
    ).toHaveValue(3);
    expect(
      screen.getByRole("spinbutton", { name: "الحد الأقصى لضيوف العقار 0" }),
    ).toHaveValue(6);
    expect(
      screen.getByRole("textbox", { name: "ملاحظات تشغيل العقار 0" }),
    ).toHaveValue("تسليم المفتاح لدى الأمن");
    expect(screen.getByText("راجع رقم الهاتف")).toBeVisible();
  });

  test("resets edited payload when the selected draft changes", () => {
    const { container, rerender } = render(
      <DataEntryReview
        confirmDraft={actions.confirm}
        rejectDraft={actions.reject}
        review={review}
      />,
    );
    fireEvent.change(screen.getByRole("textbox", { name: "اسم العميل 0" }), {
      target: { value: "اسم من المسودة الأولى" },
    });

    const nextReview: DataEntryDraftReview = {
      ...review,
      id: "draft-2",
      version: 1,
      payload: {
        ...review.payload,
        clients: [
          { ...review.payload.clients[0], displayName: "اسم المسودة الثانية" },
        ],
      },
    };
    rerender(
      <DataEntryReview
        confirmDraft={actions.confirm}
        rejectDraft={actions.reject}
        review={nextReview}
      />,
    );

    expect(screen.getByRole("textbox", { name: "اسم العميل 0" })).toHaveValue(
      "اسم المسودة الثانية",
    );
    const submittedPayload = JSON.parse(
      (
        container.querySelector(
          'input[name="payload_json"]',
        ) as HTMLInputElement
      ).value,
    ) as DataEntryDraftReview["payload"];
    expect(submittedPayload.clients[0].displayName).toBe("اسم المسودة الثانية");
    expect(
      (container.querySelector('input[name="draft_id"]') as HTMLInputElement)
        .value,
    ).toBe("draft-2");
  });

  test("keeps rejected drafts visible so storage cleanup can be retried", () => {
    const rejectedReview = { ...review, status: "rejected" } as unknown as DataEntryDraftReview;
    render(
      <DataEntryReview
        confirmDraft={actions.confirm}
        rejectDraft={actions.reject}
        review={rejectedReview}
      />,
    );

    expect(screen.getByText("تم إلغاء المسودة؛ أعد المحاولة لتنظيف الملفات الخاصة.")).toBeVisible();
    expect(screen.getByRole("button", { name: "إعادة تنظيف الملفات" })).toBeVisible();
    expect(screen.queryByRole("button", { name: "تأكيد وحفظ" })).not.toBeInTheDocument();
  });
});
