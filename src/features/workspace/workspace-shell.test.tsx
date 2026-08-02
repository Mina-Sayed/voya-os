import { render, screen } from "@testing-library/react";
import { expect, test } from "vitest";
import { WorkspaceShell } from "./workspace-shell";

test("renders the shared Arabic workspace shell with the active organization and route", () => {
  render(
    <WorkspaceShell activeHref="/workspace/leads" organizationName="فُويا للاختبار" role="manager">
      <h1>سجل العملاء المحتملين</h1>
    </WorkspaceShell>,
  );

  expect(screen.getByRole("heading", { name: "سجل العملاء المحتملين" })).toBeInTheDocument();
  expect(screen.getAllByText("فُويا للاختبار")).toHaveLength(2);
  expect(screen.getAllByText("مدير")).toHaveLength(2);
  expect(screen.getByRole("link", { name: "العملاء المحتملون" })).toHaveAttribute("aria-current", "page");
  expect(screen.getByRole("link", { name: "العملاء" })).toHaveAttribute("href", "/workspace/clients");
});

test("exposes governed AI and WhatsApp surfaces while keeping no fake disabled links", () => {
  render(
    <WorkspaceShell activeHref="/workspace" organizationName="فُويا للاختبار" role="manager">
      <h1>لوحة التشغيل</h1>
    </WorkspaceShell>,
  );

  expect(screen.getByRole("link", { name: "مركز الذكاء" })).toHaveAttribute("href", "/workspace/ai");
  expect(screen.getByRole("link", { name: "صندوق واتساب" })).toHaveAttribute("href", "/workspace/whatsapp");
  expect(screen.queryByText("قيد التجهيز")).not.toBeInTheDocument();
});

test("hides restricted navigation links for a viewer while preserving safe reads", () => {
  render(
    <WorkspaceShell activeHref="/workspace" organizationName="فُويا للاختبار" role="viewer">
      <h1>لوحة التشغيل</h1>
    </WorkspaceShell>,
  );

  expect(screen.getByRole("link", { name: "العملاء" })).toHaveAttribute("href", "/workspace/clients");
  expect(screen.queryByRole("link", { name: "مهام التشغيل" })).not.toBeInTheDocument();
  expect(screen.queryByRole("link", { name: "مركز الذكاء" })).not.toBeInTheDocument();
  expect(screen.queryByRole("link", { name: "صندوق واتساب" })).not.toBeInTheDocument();
});
