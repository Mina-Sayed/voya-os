import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  createServerClient: vi.fn(),
  revalidatePath: vi.fn(),
  reportFailure: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: mocks.createServerClient,
  createServiceRoleSupabaseClient: vi.fn(),
}));
vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));

import { discardWhatsappReplyDraftAction, sendWhatsappReplyDraftAction } from "./actions";

afterEach(() => vi.clearAllMocks());

function formData(values: Record<string, string>) {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

const idle = { status: "idle" as const, message: "" };

const storedDraft = {
  id: "draft-1",
  organization_id: "org-from-db",
  conversation_id: "conversation-from-db",
  body_text: "السعر 35000 جنيه شهرياً",
  status: "pending",
};

function stubClient(handlers: Record<string, (args: Record<string, unknown>) => { data?: unknown; error?: { code: string; message: string } | null }>) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  mocks.createServerClient.mockResolvedValue({
    rpc: vi.fn(async (name: string, args: Record<string, unknown> = {}) => {
      calls.push({ name, args });
      const handler = handlers[name];
      return handler ? handler(args) : { data: null, error: null };
    }),
  });
  return calls;
}

describe("sendWhatsappReplyDraftAction", () => {
  it("sends the stored draft body and organization, never the submitted form values", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "org-from-membership", role: "manager" });
    const calls = stubClient({
      list_whatsapp_reply_drafts_v1: () => ({ data: [storedDraft] }),
      create_whatsapp_message: () => ({ data: "message-9" }),
      mark_whatsapp_reply_draft_sent_v1: () => ({ data: "draft-1" }),
    });

    const result = await sendWhatsappReplyDraftAction(idle, formData({
      draft_id: "draft-1",
      // A tampered client payload: the action must ignore all of it.
      body_text: "نص مزيف من العميل",
      organization_id: "org-hijacked",
      conversation_id: "conversation-hijacked",
    }));

    expect(result.status).toBe("success");
    const send = calls.find((call) => call.name === "create_whatsapp_message");
    expect(send?.args).toMatchObject({
      p_organization_id: "org-from-db",
      p_conversation_id: "conversation-from-db",
      p_body_text: "السعر 35000 جنيه شهرياً",
    });
    expect(send?.args.p_idempotency_key).toBe("whatsapp-reply-draft:draft-1");
  });

  it("closes the draft after a successful send", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "org-from-membership", role: "owner" });
    const calls = stubClient({
      list_whatsapp_reply_drafts_v1: () => ({ data: [storedDraft] }),
      create_whatsapp_message: () => ({ data: "message-9" }),
      mark_whatsapp_reply_draft_sent_v1: () => ({ data: "draft-1" }),
    });

    await sendWhatsappReplyDraftAction(idle, formData({ draft_id: "draft-1" }));

    expect(calls.find((call) => call.name === "mark_whatsapp_reply_draft_sent_v1")?.args)
      .toEqual({ p_draft_id: "draft-1", p_sent_message_id: "message-9" });
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/whatsapp");
  });

  it("does not close the draft when the send itself fails", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "org-from-membership", role: "operations" });
    const calls = stubClient({
      list_whatsapp_reply_drafts_v1: () => ({ data: [storedDraft] }),
      create_whatsapp_message: () => ({ data: null, error: { code: "42501", message: "denied" } }),
    });

    const result = await sendWhatsappReplyDraftAction(idle, formData({ draft_id: "draft-1" }));

    expect(result.status).toBe("denied");
    expect(calls.some((call) => call.name === "mark_whatsapp_reply_draft_sent_v1")).toBe(false);
  });

  it("denies members outside owner, manager and operations", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "org-from-membership", role: "sales_agent" });
    const calls = stubClient({});

    const result = await sendWhatsappReplyDraftAction(idle, formData({ draft_id: "draft-1" }));

    expect(result.status).toBe("denied");
    expect(calls).toHaveLength(0);
  });

  it("denies a caller with no workspace membership before touching the database", async () => {
    mocks.loadMembership.mockResolvedValue(null);
    const calls = stubClient({});

    expect((await sendWhatsappReplyDraftAction(idle, formData({ draft_id: "draft-1" }))).status).toBe("denied");
    expect(calls).toHaveLength(0);
  });

  it("rejects a draft that is missing, already sent, or not returned to this caller", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "org-from-membership", role: "manager" });
    const calls = stubClient({
      list_whatsapp_reply_drafts_v1: () => ({ data: [{ ...storedDraft, id: "other", status: "sent" }] }),
      create_whatsapp_message: () => ({ data: "message-9" }),
    });

    const result = await sendWhatsappReplyDraftAction(idle, formData({ draft_id: "draft-1" }));

    expect(result.status).toBe("invalid");
    expect(calls.some((call) => call.name === "create_whatsapp_message")).toBe(false);
  });


  it("does not report success when the draft fails to close after the message was queued", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "org-from-membership", role: "manager" });
    stubClient({
      list_whatsapp_reply_drafts_v1: () => ({ data: [storedDraft] }),
      create_whatsapp_message: () => ({ data: "message-9" }),
      mark_whatsapp_reply_draft_sent_v1: () => ({ data: null, error: { code: "40001", message: "already sent" } }),
    });

    const result = await sendWhatsappReplyDraftAction(idle, formData({ draft_id: "draft-1" }));

    // The message is queued and must not be retried blindly, so the operator is told.
    expect(result.status).toBe("retry");
    expect(result.message).toContain("المسودة");
    expect(mocks.reportFailure).toHaveBeenCalled();
  });

  it("requires a draft id", async () => {
    expect((await sendWhatsappReplyDraftAction(idle, formData({}))).status).toBe("invalid");
    expect(mocks.createServerClient).not.toHaveBeenCalled();
  });
});

describe("discardWhatsappReplyDraftAction", () => {
  it("discards a pending draft for an authorized role", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "org-from-membership", role: "operations" });
    const calls = stubClient({ discard_whatsapp_reply_draft_v1: () => ({ data: "draft-1" }) });

    const result = await discardWhatsappReplyDraftAction(idle, formData({ draft_id: "draft-1" }));

    expect(result.status).toBe("success");
    expect(calls[0]).toEqual({ name: "discard_whatsapp_reply_draft_v1", args: { p_draft_id: "draft-1" } });
  });

  it("denies a member outside owner, manager and operations", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "org-from-membership", role: "sales_agent" });
    const calls = stubClient({ discard_whatsapp_reply_draft_v1: () => ({ data: "draft-1" }) });

    expect((await discardWhatsappReplyDraftAction(idle, formData({ draft_id: "draft-1" }))).status).toBe("denied");
    expect(calls).toHaveLength(0);
  });
});