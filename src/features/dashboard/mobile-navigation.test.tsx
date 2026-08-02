import { fireEvent, render, screen } from "@testing-library/react";
import { expect, test } from "vitest";
import { MobileNavigation } from "./mobile-navigation";

test("opens, renders active destinations and disabled product surfaces, then closes on Escape", () => {
  render(
    <MobileNavigation
      items={[
        { href: "/workspace", label: "نظرة عامة" },
        { label: "الإعدادات", disabledReason: "قريبًا" },
      ]}
    />,
  );

  const toggle = screen.getByRole("button", { name: "فتح التنقل" });
  expect(toggle).toHaveAttribute("aria-expanded", "false");
  fireEvent.click(toggle);

  expect(toggle).toHaveAttribute("aria-expanded", "true");
  expect(screen.getByRole("link", { name: "نظرة عامة" })).toHaveAttribute("href", "/workspace");
  expect(screen.getByTitle("قريبًا")).toHaveTextContent("الإعدادات");
  fireEvent.keyDown(window, { key: "Escape" });

  expect(screen.queryByRole("navigation", { name: "التنقل على الهاتف" })).not.toBeInTheDocument();
});

test("closes after selecting a destination or with the close button", () => {
  const { rerender } = render(
    <MobileNavigation items={[{ href: "/workspace", label: "نظرة عامة" }]} />,
  );
  const toggle = screen.getByRole("button", { name: "فتح التنقل" });
  fireEvent.click(toggle);
  fireEvent.click(screen.getByRole("link", { name: "نظرة عامة" }));
  expect(screen.queryByRole("navigation", { name: "التنقل على الهاتف" })).not.toBeInTheDocument();

  rerender(<MobileNavigation items={[{ href: "/workspace", label: "نظرة عامة" }]} />);
  fireEvent.click(screen.getByRole("button", { name: "فتح التنقل" }));
  fireEvent.click(screen.getByRole("button", { name: "إغلاق التنقل" }));
  expect(screen.queryByRole("navigation", { name: "التنقل على الهاتف" })).not.toBeInTheDocument();
});
