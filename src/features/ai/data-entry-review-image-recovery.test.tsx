import { render, screen } from "@testing-library/react";
import { describe, expect, test } from "vitest";
import type { DataEntryActionState } from "@/app/workspace/ai/data-entry-actions";
import { DataEntryReview } from "./data-entry-review";

const action = async (): Promise<DataEntryActionState> => ({ status: "idle", message: "" });

describe("AI data-entry image recovery UI", () => {
  test("locks an applied property record but keeps its failed image mapping editable", () => {
    render(<DataEntryReview
      confirmDraft={action}
      rejectDraft={action}
      review={{
        id: "11111111-1111-4111-8111-111111111111",
        status: "partially_applied",
        version: 7,
        sourceText: "",
        payload: {
          clients: [],
          properties: [{
            code: "REC-1",
            name: "Recovered property",
            timezone: "Africa/Cairo",
            address: null,
            city: null,
            unitLabel: null,
            bedrooms: null,
            maxGuests: null,
            operationalNotes: null,
            imageInputIds: ["22222222-2222-4222-8222-222222222222"],
            confidence: "high",
            missingRequired: [],
          }],
          unresolved: [],
          warnings: [],
        },
        inputs: [{
          id: "22222222-2222-4222-8222-222222222222",
          mimeType: "image/png",
          byteSize: 2048,
          status: "active",
          mappedPropertyId: null,
        }],
        applicationResult: {
          clients: [],
          properties: [{ index: 0, recordId: "33333333-3333-4333-8333-333333333333" }],
          images: [{
            propertyIndex: 0,
            inputId: "22222222-2222-4222-8222-222222222222",
            errorCode: "image_register_failed",
          }],
        },
      }}
    />);

    expect(screen.getByLabelText("كود العقار 0")).toBeDisabled();
    expect(screen.getByLabelText("ربط الصورة 22222222-2222-4222-8222-222222222222 بالعقار 0")).toBeEnabled();
    expect(screen.getByText("تم نسخ الصورة لكن تعذر تسجيلها كسجل صورة للعقار.")).toBeInTheDocument();
  });
});


test("does not request an intake preview after the image was mapped and cleaned", () => {
  render(<DataEntryReview
    confirmDraft={action}
    rejectDraft={action}
    review={{
      id: "11111111-1111-4111-8111-111111111111",
      status: "partially_applied",
      version: 8,
      sourceText: "",
      payload: {
        clients: [],
        properties: [{
          code: "REC-2",
          name: "Mapped property",
          timezone: "Africa/Cairo",
          address: null,
          city: null,
          unitLabel: null,
          bedrooms: null,
          maxGuests: null,
          operationalNotes: null,
          imageInputIds: ["22222222-2222-4222-8222-222222222222"],
          confidence: "high",
          missingRequired: [],
        }],
        unresolved: [],
        warnings: [],
      },
      inputs: [{
        id: "22222222-2222-4222-8222-222222222222",
        mimeType: "image/png",
        byteSize: 2048,
        status: "mapped",
        mappedPropertyId: "33333333-3333-4333-8333-333333333333",
      }],
      applicationResult: {
        clients: [],
        properties: [{ index: 0, recordId: "33333333-3333-4333-8333-333333333333" }],
        images: [{
          propertyIndex: 0,
          inputId: "22222222-2222-4222-8222-222222222222",
          recordId: "44444444-4444-4444-8444-444444444444",
        }],
      },
    }}
  />);

  expect(screen.getByText("تم نقل الصورة إلى صور العقار")).toBeInTheDocument();
  expect(screen.queryByAltText("معاينة صورة الإدخال 22222222")).not.toBeInTheDocument();
  expect(screen.getByLabelText("ربط الصورة 22222222-2222-4222-8222-222222222222 بالعقار 0")).toBeDisabled();
});
