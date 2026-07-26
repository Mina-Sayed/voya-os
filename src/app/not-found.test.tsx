import { render, screen } from "@testing-library/react";
import { expect, test } from "vitest";
import NotFound from "./not-found";

test("shows an Arabic not-found message with a fixed return link", () => {
  render(<NotFound />);

  expect(screen.getByRole("heading", { name: "الصفحة غير موجودة" })).toBeVisible();
  expect(screen.getByRole("link", { name: "العودة إلى لوحة العمليات" })).toHaveAttribute("href", "/");
});
