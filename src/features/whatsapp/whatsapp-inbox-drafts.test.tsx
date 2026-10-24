import { act, render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { WhatsAppInboxPage, type WhatsAppReplyDraftItem } from "./whatsapp-inbox-page";

const action = vi.fn(async () => ({ status: "success" as const, message: "تم" }));

const channel = { id: "channel-a", provider: "sandbox", externalChannelId: "channel-a", displayName: "قناة الاختبار", status: "active", killSwitch: false, createdAt: "2026-08-01T10:00:00Z" };
const conversation = { id: "conversation-a", channelId: "channel-a", channelName: "قناة الاختبار", contactLabel: "عميل النيل", status: "open", assignedMembershipId: null, lastMessageAt: "2026-08-01T10:01:00Z", lastMessagePreview: "أحتاج شقة", lastMessageDirection: "inbound" as const };

const draft: WhatsAppReplyDraftItem = {
  id: "draft-1",
  conversationId: "conversation-a",
  bodyText: "السعر 35000 جنيه شهرياً",
  reviewReasons: ["monetary_amount"],
  createdAt: "2026-08-01T10:02:00Z",
};

function renderInbox(props: Partial<Parameters<typeof WhatsAppInboxPage>[0]> = {}) {
  render(
    <WhatsAppInboxPage
      addNote={action}
      canManageChannels={false}
      channels={[channel]}
      conversations={[conversation]}
      createChannel={action}
      sendMessage={action}
      {...props}
    />,
  );
}

test("renders nothing about drafts when the inbox has no drafts", () => {
  renderInbox();

  expect(screen.queryByRole("heading", { name: "مسودات بانتظار موافقتك" })).not.toBeInTheDocument();
});

test("shows the withheld reply and why it needs a human", () => {
  renderInbox({ replyDrafts: [draft], sendReplyDraft: action, discardReplyDraft: action });

  expect(screen.getByRole("heading", { name: "مسودات بانتظار موافقتك" })).toBeInTheDocument();
  expect(screen.getByText("السعر 35000 جنيه شهرياً")).toBeInTheDocument();
  expect(screen.getByText("تحتوي على سعر أو مبلغ")).toBeInTheDocument();
  expect(screen.getByRole("button", { name: /إرسال الآن/ })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "تجاهل" })).toBeInTheDocument();
});

test("labels every review reason in arabic and falls back for unknown reasons", () => {
  renderInbox({
    replyDrafts: [{ ...draft, reviewReasons: ["booking_commitment", "availability_commitment", "future_reason"] }],
    sendReplyDraft: action,
  });

  expect(screen.getByText("تؤكد حجزاً")).toBeInTheDocument();
  expect(screen.getByText("تؤكد توافر وحدة")).toBeInTheDocument();
  expect(screen.getByText("تحتاج مراجعة بشرية")).toBeInTheDocument();
});

test("submits only the draft id, never the draft body", () => {
  renderInbox({ replyDrafts: [draft], sendReplyDraft: action });

  const form = screen.getByRole("button", { name: /إرسال الآن/ }).closest("form");
  expect(form).not.toBeNull();
  const inputs = Array.from(form?.querySelectorAll("input") ?? []);
  expect(inputs.map((input) => input.getAttribute("name"))).toEqual(["draft_id"]);
  expect(inputs[0]?.getAttribute("value")).toBe("draft-1");
});

test("renders drafts read-only when the viewer cannot send them", () => {
  renderInbox({ replyDrafts: [draft] });

  expect(screen.getByRole("heading", { name: "مسودات بانتظار موافقتك" })).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: /إرسال الآن/ })).not.toBeInTheDocument();
});

test("keeps drafts scoped to their own conversation", () => {
  renderInbox({
    conversations: [{ ...conversation, id: "conversation-b" }],
    replyDrafts: [draft],
    sendReplyDraft: action,
  });

  expect(screen.queryByRole("heading", { name: "مسودات بانتظار موافقتك" })).not.toBeInTheDocument();
});

test("lets the browser pick the body direction so a latin reply is not laid out RTL", () => {
  renderInbox({ replyDrafts: [draft, { ...draft, id: "draft-2", bodyText: "The studio is still available." }], sendReplyDraft: action });

  for (const body of screen.getAllByText(/السعر 35000 جنيه|The studio is still available/)) {
    expect(body).toHaveAttribute("dir", "auto");
  }
});

test("gives every send and discard button the draft body as its description", () => {
  renderInbox({ replyDrafts: [draft], sendReplyDraft: action, discardReplyDraft: action });

  const bodyId = screen.getByText("السعر 35000 جنيه شهرياً").id;
  expect(bodyId).not.toBe("");
  for (const button of [screen.getByRole("button", { name: /إرسال الآن/ }), screen.getByRole("button", { name: "تجاهل" })]) {
    expect(button).toHaveAttribute("aria-describedby", bodyId);
  }
});

test("scopes each drafts heading id to its own conversation card", () => {
  const other = { ...conversation, id: "conversation-b", contactLabel: "عميل الدلتا" };
  const otherDraft = { ...draft, id: "draft-2", conversationId: "conversation-b", bodyText: "مسودة المحادثة الأخرى" };
  const { container } = render(
    <WhatsAppInboxPage
      addNote={action}
      canManageChannels={false}
      channels={[channel]}
      conversations={[conversation, other]}
      createChannel={action}
      replyDrafts={[draft, otherDraft]}
      sendMessage={action}
      sendReplyDraft={action}
    />,
  );

  const ids = [...container.querySelectorAll("section[aria-labelledby^='reply-drafts-']")].map((section) => section.getAttribute("aria-labelledby"));
  expect(ids).toEqual(["reply-drafts-conversation-a", "reply-drafts-conversation-b"]);
  expect(new Set(ids).size).toBe(ids.length);
});

test("does not tell a viewer who cannot send that they can send", () => {
  renderInbox({ replyDrafts: [draft] });

  expect(screen.getByText(/لا تملك صلاحية إرسالها أو تجاهلها/)).toBeInTheDocument();
  expect(screen.queryByText(/أرسلها بنفسك أو تجاهلها/)).not.toBeInTheDocument();
});

test("shows a draft result under its own draft and never under another", async () => {
  const denied = vi.fn(async () => ({ status: "denied" as const, message: "تعذر تسجيل رد المسودة." }));
  const { container } = render(
    <WhatsAppInboxPage
      addNote={action}
      canManageChannels={false}
      channels={[channel]}
      conversations={[conversation]}
      createChannel={action}
      replyDrafts={[draft, { ...draft, id: "draft-2", bodyText: "مسودة ثانية" }]}
      sendMessage={action}
      sendReplyDraft={denied}
    />,
  );

  await act(async () => {
    screen.getAllByRole("button", { name: /إرسال الآن/ })[0].click();
  });

  // Direct children of the drafts list only: the reason chips are nested <li>s too.
  const items = [...container.querySelectorAll("section[aria-labelledby^='reply-drafts-'] > ul > li")];
  expect(items).toHaveLength(2);
  const feedback = items.map((item) => item.querySelector("p[aria-live]")?.textContent ?? "");
  expect(feedback[0]).toBe("تعذر تسجيل رد المسودة.");
  expect(feedback[1]).toBe("");
});