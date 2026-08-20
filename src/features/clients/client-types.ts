export type ClientListItem = Readonly<{
  id: string;
  displayName: string;
  phone?: string | null;
  whatsapp?: string | null;
  email?: string | null;
  nationality?: string | null;
  preferredLanguage?: string | null;
  notes?: string | null;
  sourceLeadId?: string | null;
  version?: number;
  createdAt: string;
  updatedAt?: string;
  archivedAt?: string | null;
  duplicateWarning?: boolean;
}>;
