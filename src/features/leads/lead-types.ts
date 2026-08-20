export type LeadActivityItem = Readonly<{
  id: string;
  leadId: string;
  actorMembershipId: string;
  activityType: string;
  content: string;
  createdAt: string;
}>;

export type LeadFollowUpItem = Readonly<{
  id: string;
  leadId: string;
  assignedMembershipId: string | null;
  dueAt: string;
  note: string;
  status: "pending" | "completed" | "cancelled" | string;
  completedAt: string | null;
  completedByMembershipId: string | null;
  createdAt: string;
}>;

export type LeadItem = Readonly<{
  id: string;
  name?: string | null;
  title?: string | null;
  phone?: string | null;
  whatsapp?: string | null;
  email?: string | null;
  source: string;
  status: string;
  assignedMembershipId?: string | null;
  requestedArea?: string | null;
  requestedCheckIn: string | null;
  requestedCheckOut: string | null;
  guests?: number | null;
  bedrooms?: number | null;
  budgetText?: string | null;
  notes?: string | null;
  nextFollowUpAt?: string | null;
  version?: number;
  convertedClientId?: string | null;
  archivedAt?: string | null;
  createdAt: string;
  updatedAt?: string;
  duplicateWarning?: boolean;
  activities?: readonly LeadActivityItem[];
  followUps?: readonly LeadFollowUpItem[];
}>;

export function leadDisplayName(lead: Pick<LeadItem, "name" | "title">): string {
  return lead.name?.trim() || lead.title?.trim() || "طلب بدون اسم";
}
