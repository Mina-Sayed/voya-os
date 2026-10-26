import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { StaySearchForm } from "./stay-search-form";

describe("StaySearchForm", () => {
  it("labels the destination, stay dates, and guest selector", () => {
    render(<StaySearchForm />);

    expect(screen.getByLabelText("المدينة أو المنطقة")).toBeInTheDocument();
    expect(screen.getByLabelText("تاريخ الوصول")).toBeInTheDocument();
    expect(screen.getByLabelText("تاريخ المغادرة")).toBeInTheDocument();
    expect(screen.getByLabelText("عدد الضيوف")).toBeInTheDocument();
  });

  it("announces the first missing field and focuses it", () => {
    render(<StaySearchForm />);

    fireEvent.click(screen.getByRole("button", { name: "ابحث عن إقامة" }));

    expect(screen.getByRole("alert")).toHaveTextContent("أدخل المدينة أو المنطقة.");
    expect(screen.getByLabelText("المدينة أو المنطقة")).toHaveFocus();
  });

  it("rejects a departure date that is not after arrival", () => {
    render(<StaySearchForm />);
    fireEvent.change(screen.getByLabelText("المدينة أو المنطقة"), { target: { value: "القاهرة" } });
    fireEvent.change(screen.getByLabelText("تاريخ الوصول"), { target: { value: "2026-10-10" } });
    fireEvent.change(screen.getByLabelText("تاريخ المغادرة"), { target: { value: "2026-10-10" } });
    fireEvent.change(screen.getByLabelText("عدد الضيوف"), { target: { value: "2" } });

    fireEvent.submit(screen.getByLabelText("المدينة أو المنطقة").closest("form")!);

    expect(screen.getByRole("alert")).toHaveTextContent("اختر تاريخ مغادرة بعد تاريخ الوصول.");
    expect(screen.getByLabelText("تاريخ المغادرة")).toHaveFocus();
  });

  it("submits validated search criteria through a same-site GET form", () => {
    render(<StaySearchForm />);
    const form = screen.getByLabelText("المدينة أو المنطقة").closest("form");
    expect(form).toHaveAttribute("action", "/stay/search");
    expect(form).toHaveAttribute("method", "get");
    expect(screen.getByLabelText("تاريخ الوصول")).toHaveAttribute("name", "check_in");
    expect(screen.getByLabelText("تاريخ المغادرة")).toHaveAttribute("name", "check_out");
    expect(screen.getByText("التوفر المعروض إرشادي؛ إرسال طلب إقامة لا يؤكد الحجز أو يحجز التواريخ.")).toBeInTheDocument();
  });
});
