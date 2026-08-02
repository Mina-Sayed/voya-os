import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { WhatsAppInboxPage } from "./whatsapp-inbox-page";

const action = vi.fn(async () => ({ status: "success" as const, message: "تم" }));

test("renders an honest empty state when no provider channel or conversation exists", () => {
  render(
    <WhatsAppInboxPage
      addNote={action}
      canManageChannels
      channels={[]}
      conversations={[]}
      createChannel={action}
      sendMessage={action}
    />,
  );

  expect(screen.getByRole("heading", { name: "صندوق واتساب" })).toBeInTheDocument();
  expect(screen.getByRole("heading", { name: "لا توجد قناة نشطة بعد" })).toBeInTheDocument();
  expect(screen.getByRole("heading", { name: "لا توجد محادثات في نطاقك" })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: /حفظ تعريف القناة/ })).toBeInTheDocument();
});

test("renders staff reply and internal-note controls for a tenant conversation", () => {
  render(
    <WhatsAppInboxPage
      addNote={action}
      canManageChannels={false}
      channels={[{ id: "channel-a", provider: "sandbox", externalChannelId: "channel-a", displayName: "قناة الاختبار", status: "active", killSwitch: false, createdAt: "2026-08-01T10:00:00Z" }]}
      conversations={[{ id: "conversation-a", channelId: "channel-a", channelName: "قناة الاختبار", contactLabel: "عميل النيل", status: "open", assignedMembershipId: null, lastMessageAt: "2026-08-01T10:01:00Z", lastMessagePreview: "أحتاج شقة في الزمالك", lastMessageDirection: "inbound" }]}
      createChannel={action}
      sendMessage={action}
    />,
  );

  expect(screen.getByRole("heading", { name: "عميل النيل" })).toBeInTheDocument();
  expect(screen.getByText("أحتاج شقة في الزمالك")).toBeInTheDocument();
  expect(screen.getByRole("button", { name: /تسجيل الرد للإرسال/ })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: /حفظ الملاحظة/ })).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: /حفظ تعريف القناة/ })).not.toBeInTheDocument();
});
