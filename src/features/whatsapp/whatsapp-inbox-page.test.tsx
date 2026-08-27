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

test("renders AI state, structured owner draft, messages, image preview, and takeover controls", () => {
  render(
    <WhatsAppInboxPage
      addNote={action}
      canManageChannels={false}
      channels={[{ id: "channel-a", provider: "sandbox", externalChannelId: "channel-a", displayName: "قناة الاختبار", status: "active", killSwitch: false, createdAt: "2026-08-01T10:00:00Z" }]}
      conversations={[{
        id: "conversation-owner",
        channelId: "channel-a",
        channelName: "قناة الاختبار",
        contactLabel: "أحمد",
        status: "open",
        assignedMembershipId: null,
        lastMessageAt: "2026-08-01T10:01:00Z",
        lastMessagePreview: "عندي شقة مفروشة",
        lastMessageDirection: "inbound",
        aiEnabled: true,
        conversationType: "owner_onboarding",
        aiStateVersion: 2,
        structuredState: { owner: { displayName: "أحمد" }, property: { city: "Nasr City", district: "Abbas El Akkad", bedrooms: 3, bathrooms: 2, monthlyPrice: 35000, currency: "EGP" }, missingFields: ["property.photos"], confidence: "high" },
        recentMessages: [{ id: "image-message", direction: "inbound", message_type: "image", body_text: "صورة مرفقة", caption: null, media_status: "stored" }],
      }]}
      createChannel={action}
      sendMessage={action}
      toggleAi={action}
      confirmProperty={action}
    />,
  );

  expect(screen.getAllByText("مالك عقار").length).toBeGreaterThan(0);
  expect(screen.getByText("AI نشط")).toBeInTheDocument();
  expect(screen.getByText("Nasr City / Abbas El Akkad")).toBeInTheDocument();
  expect(screen.getByText("3 غرف · 2 حمام")).toBeInTheDocument();
  expect(screen.getByRole("button", { name: /استلام المحادثة/ })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: /مراجعة وتأكيد/ })).toBeInTheDocument();
  expect(screen.getByLabelText("المساحة بالمتر")).toBeInTheDocument();
  expect(screen.getByLabelText("أقل مدة إقامة")).toBeInTheDocument();
  expect(screen.getByRole("img", { name: /صورة من المحادثة/ })).toBeInTheDocument();
});
