import { requireWorkspaceMembership, } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { WhatsAppInboxPage, type WhatsAppChannelItem, type WhatsAppConversationItem } from "@/features/whatsapp/whatsapp-inbox-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { addWhatsappNoteAction, createWhatsappChannelAction, createWhatsappMessageAction } from "./actions";

type ChannelRow = Readonly<{
  id: string;
  provider: string;
  external_channel_id: string;
  display_name: string;
  status: string;
  kill_switch: boolean;
  created_at: string;
}>;

type ConversationRow = Readonly<{
  id: string;
  channel_id: string;
  channel_name: string;
  contact_label: string;
  status: string;
  assigned_membership_id: string | null;
  last_message_at: string | null;
  last_message_preview: string | null;
  last_message_direction: string | null;
}>;

async function loadInbox(organizationId: string) {
  const client = await createServerSupabaseClient();
  const [channelsResult, conversationsResult] = await Promise.all([
    client.rpc("list_whatsapp_channels", { p_organization_id: organizationId }),
    client.rpc("list_whatsapp_conversations", { p_organization_id: organizationId }),
  ]);
  if (channelsResult.error || conversationsResult.error) {
    throwWorkspaceOperationError("workspace.whatsapp.read", channelsResult.error ?? conversationsResult.error);
  }
  return {
    channels: ((channelsResult.data ?? []) as ChannelRow[]).map((channel): WhatsAppChannelItem => ({
      id: channel.id,
      provider: channel.provider,
      externalChannelId: channel.external_channel_id,
      displayName: channel.display_name,
      status: channel.status,
      killSwitch: channel.kill_switch,
      createdAt: channel.created_at,
    })),
    conversations: ((conversationsResult.data ?? []) as ConversationRow[]).map((conversation): WhatsAppConversationItem => ({
      id: conversation.id,
      channelId: conversation.channel_id,
      channelName: conversation.channel_name,
      contactLabel: conversation.contact_label,
      status: conversation.status,
      assignedMembershipId: conversation.assigned_membership_id,
      lastMessageAt: conversation.last_message_at,
      lastMessagePreview: conversation.last_message_preview,
      lastMessageDirection: conversation.last_message_direction,
    })),
  };
}

export default async function WhatsAppWorkspacePage() {
  const membership = await requireWorkspaceMembership(new Set(["owner", "manager", "sales_agent", "operations"]));
  const inbox = await loadInbox(membership.organizationId);
  return (
    <WorkspaceShell activeHref="/workspace/whatsapp" organizationName={membership.organizationName} role={membership.role}>
      <WhatsAppInboxPage
        addNote={addWhatsappNoteAction}
        canManageChannels={membership.role === "owner" || membership.role === "manager"}
        channels={inbox.channels}
        conversations={inbox.conversations}
        createChannel={createWhatsappChannelAction}
        sendMessage={createWhatsappMessageAction}
      />
    </WorkspaceShell>
  );
}
