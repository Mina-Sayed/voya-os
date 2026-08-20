import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { LeadCreateForm } from "./lead-create-form";

test("requires a lead name before creating a CRM lead", () => {
  render(<LeadCreateForm createLead={vi.fn()} />);
  expect(screen.getByLabelText("اسم / عنوان الطلب")).toBeRequired();
  expect(screen.getByText(/وسيلة اتصال واحدة على الأقل/)).toBeInTheDocument();
});
