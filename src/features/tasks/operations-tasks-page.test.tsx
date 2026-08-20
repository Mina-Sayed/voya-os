import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { OperationsTasksPage } from "./operations-tasks-page";

const createTask = vi.fn(async () => ({ status: "success" as const, message: "تم" }));
const updateStatus = vi.fn(async () => undefined);

test("renders an honest empty operations task queue", () => {
  render(<OperationsTasksPage assignees={[]} createTask={createTask} tasks={[]} updateStatus={updateStatus} />);
  expect(screen.getByRole("heading", { name: "مهام التشغيل" })).toBeInTheDocument();
  expect(screen.getByRole("heading", { name: "لا توجد مهام بعد" })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: /إضافة المهمة/ })).toBeInTheDocument();
});

test("renders task status and guarded completion controls", () => {
  render(<OperationsTasksPage assignees={[{ id: "member-a", display_name: "فريق التشغيل", role: "operator", status: "active" }]} createTask={createTask} tasks={[{ id: "task-a", taskType: "check_in", title: "تجهيز وصول", description: "تحقق من المفاتيح", status: "open", dueAt: "2026-08-01T10:00:00Z", bookingId: null, assignedMembershipId: "member-a", assignedDisplayName: "فريق التشغيل", createdAt: "2026-08-01T09:00:00Z", updatedAt: "2026-08-01T09:00:00Z" }]} updateStatus={updateStatus} />);
  expect(screen.getByRole("heading", { name: "تجهيز وصول" })).toBeInTheDocument();
  expect(screen.getAllByText("مفتوحة").length).toBeGreaterThanOrEqual(1);
  expect(screen.getByText("مسندة إلى فريق التشغيل")).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "إكمال" })).toBeInTheDocument();
});
