import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { LeadsPage } from "./leads-page";

describe("LeadsPage", () => {
  it("renders an Arabic CRM lead registry", () => {
    render(<LeadsPage leads={[{ id: "lead-a", title: "إقامة صيفية", source: "website", status: "new", requestedCheckIn: "2027-06-01", requestedCheckOut: "2027-06-05", createdAt: "2026-07-22T00:00:00.000Z" }]} timeZone="Africa/Cairo" />);
    expect(screen.getByRole("heading", { name: "العملاء المحتملون" })).toBeInTheDocument();
    expect(screen.getByText("إقامة صيفية")).toBeInTheDocument();
    expect(screen.getByText(/سجل موحد للطلب والاتصال والنشاط والمتابعة/)).toBeInTheDocument();
  });

  it("keeps the existing assignee in the edit form when saving other lead fields", () => {
    const { container } = render(<LeadsPage
      leads={[{
        id: "lead-assigned",
        name: "عميل مسند",
        source: "website",
        status: "new",
        assignedMembershipId: "membership-owner",
        requestedCheckIn: null,
        requestedCheckOut: null,
        createdAt: "2026-01-15T10:00:00.000Z",
      }]}
      timeZone="Africa/Cairo"
      updateLead={async () => ({ status: "idle", message: "" })}
    />);

    const editForm = container.querySelector("form");
    expect(editForm).not.toBeNull();
    expect(new FormData(editForm!).get("assigned_membership_id")).toBe("membership-owner");
  });

  it("formats lead activity and follow-up times in the organization timezone", () => {
    const winter = "2026-01-15T10:00:00.000Z";
    const summer = "2026-07-15T10:00:00.000Z";
    const { container } = render(<LeadsPage leads={[{
      id: "lead-times",
      name: "عميل",
      source: "website",
      status: "new",
      requestedCheckIn: null,
      requestedCheckOut: null,
      createdAt: "2026-01-01T00:00:00.000Z",
      activities: [{ id: "activity-winter", leadId: "lead-times", actorMembershipId: "member-a", activityType: "note", content: "ملاحظة", createdAt: winter }],
      followUps: [{ id: "follow-up-summer", leadId: "lead-times", assignedMembershipId: null, dueAt: summer, note: "متابعة", status: "pending", completedAt: null, completedByMembershipId: null, createdAt: "2026-01-01T00:00:00.000Z" }],
    }]} timeZone="Africa/Cairo" />);
    const details = container.querySelector("details");
    expect(details).not.toBeNull();
    details!.open = true;

    expect(container.querySelector(`time[datetime="${winter}"]`)).toHaveTextContent(/١٢:٠٠/u);
    expect(container.querySelector(`time[datetime="${summer}"]`)).toHaveTextContent(/١:٠٠/u);
  });
});
