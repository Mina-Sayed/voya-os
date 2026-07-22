import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { LeadCreateForm } from "./lead-create-form";

test("requires title before creating an operational lead", () => {
  render(<LeadCreateForm createLead={vi.fn()} />);
  expect(screen.getByLabelText("عنوان الطلب")).toBeRequired();
  expect(screen.getByText(/لا بيانات اتصال أو أسعار/)).toBeInTheDocument();
});
