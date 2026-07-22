import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { NotificationsPage } from "./notifications-page";

describe("NotificationsPage", () => {
  it("renders an unread operational notification with a read control", () => {
    render(<NotificationsPage markRead={vi.fn()} notifications={[{ id: "notification-a", category: "operational", title: "تنبيه تشغيلي", body: "تمت إضافة حظر توفر.", readAt: null, createdAt: "2026-07-22T00:00:00.000Z" }]} />);
    expect(screen.getByRole("heading", { name: "الإشعارات" })).toBeInTheDocument();
    expect(screen.getByText("تنبيه تشغيلي")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "تمت القراءة" })).toBeInTheDocument();
  });

  it("explains an empty inbox", () => {
    render(<NotificationsPage markRead={vi.fn()} notifications={[]} />);
    expect(screen.getByText("لا توجد إشعارات حالياً")).toBeInTheDocument();
  });
});
