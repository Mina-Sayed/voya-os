import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ClientArchiveForm, ClientEditForm } from "@/features/clients/client-command-forms";
import {
  LeadActivityForm,
  LeadArchiveForm,
  LeadConvertForm,
  LeadDetailsSummary,
  LeadEditForm,
  LeadFollowUpCompleteForm,
  LeadFollowUpForm,
} from "@/features/leads/lead-command-forms";

const lead = {
  id: "lead-a",
  name: "أحمد النيل",
  title: null,
  phone: "+201000000602",
  whatsapp: "+201000000602",
  email: "lead@example.test",
  source: "website",
  status: "new",
  assignedMembershipId: null,
  requestedArea: "المعادي",
  requestedCheckIn: "2027-06-01",
  requestedCheckOut: "2027-06-05",
  guests: 2,
  bedrooms: 1,
  budgetText: "25000 جنيه",
  notes: "إقامة عائلية",
  nextFollowUpAt: "2027-05-20T10:00:00.000Z",
  version: 1,
  convertedClientId: null,
  archivedAt: null,
  createdAt: "2026-07-22T00:00:00.000Z",
  updatedAt: "2026-07-22T00:00:00.000Z",
  duplicateWarning: false,
  activities: [],
  followUps: [{
    id: "follow-up-a",
    leadId: "lead-a",
    assignedMembershipId: null,
    dueAt: "2027-05-20T10:00:00.000Z",
    note: "اتصال متابعة",
    status: "pending",
    completedAt: null,
    completedByMembershipId: null,
    createdAt: "2026-07-22T00:00:00.000Z",
  }],
};

const client = {
  id: "client-a",
  displayName: "عميل النيل",
  phone: "+201000000603",
  whatsapp: null,
  email: "client@example.test",
  nationality: "مصري",
  preferredLanguage: "ar",
  notes: "عميل متكرر",
  sourceLeadId: "lead-a",
  version: 1,
  createdAt: "2026-07-22T00:00:00.000Z",
  updatedAt: "2026-07-22T00:00:00.000Z",
  archivedAt: null,
  duplicateWarning: false,
};

describe("CRM command forms", () => {
  it("renders the lead lifecycle controls and client controls", () => {
    const action = vi.fn().mockResolvedValue({ status: "success", message: "تم الحفظ." });
    render(
      <div>
        <LeadEditForm lead={lead} updateLead={action} />
        <LeadActivityForm leadId="lead-a" createActivity={action} />
        <LeadFollowUpForm leadId="lead-a" createFollowUp={action} />
        <LeadFollowUpCompleteForm followUp={lead.followUps[0]} completeFollowUp={action} />
        <LeadConvertForm leadId="lead-a" convertLead={action} />
        <LeadArchiveForm lead={lead} archiveLead={action} />
        <LeadDetailsSummary lead={lead} />
        <ClientEditForm client={client} updateClient={action} />
        <ClientArchiveForm client={client} archiveClient={action} />
      </div>,
    );

    expect(screen.getByDisplayValue("أحمد النيل")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "إضافة للسجل" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "جدولة متابعة" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "تحويل إلى عميل" })).toBeInTheDocument();
    expect(screen.getByText("1 متابعة معلقة")).toBeInTheDocument();
    expect(screen.getByDisplayValue("عميل النيل")).toBeInTheDocument();
  });

  it("submits lead activity and displays the command response", async () => {
    const createActivity = vi.fn().mockResolvedValue({ status: "success", message: "تم تسجيل النشاط." });
    render(<LeadActivityForm leadId="lead-a" createActivity={createActivity} />);
    fireEvent.change(screen.getByRole("textbox", { name: "ما الذي حدث؟" }), { target: { value: "تم التواصل مع العميل" } });
    fireEvent.click(screen.getByRole("button", { name: "إضافة للسجل" }));

    await screen.findByText("تم تسجيل النشاط.");
    expect(createActivity).toHaveBeenCalledOnce();
  });

  it("submits a client archive reason", async () => {
    const archiveClient = vi.fn().mockResolvedValue({ status: "invalid", message: "سبب الأرشفة مطلوب." });
    render(<ClientArchiveForm client={client} archiveClient={archiveClient} />);
    fireEvent.change(screen.getByRole("textbox", { name: "سبب الأرشفة" }), { target: { value: "سجل مكرر" } });
    fireEvent.click(screen.getByRole("button", { name: "أرشفة العميل" }));

    await screen.findByText("سبب الأرشفة مطلوب.");
    expect(archiveClient).toHaveBeenCalledOnce();
  });
});
