import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { PropertyOwnerArchiveForm } from "./property-owner-archive-form";
import { PropertyOwnerEditForm } from "./property-owner-edit-form";
import { PropertyOwnerRestoreForm } from "./property-owner-restore-form";

const owner = {
  id: "owner-a",
  displayName: "شركة النخيل",
  status: "active" as const,
  phone: "+201000000601",
  whatsapp: "+201000000601",
  email: "owner@example.test",
  preferredContactMethod: "whatsapp",
  notes: "اتصال أساسي",
  version: 2,
  createdAt: "2026-07-22T00:00:00.000Z",
  archivedAt: null,
};

describe("property-owner command forms", () => {
  it("renders edit and archive controls for an active owner", () => {
    const action = vi.fn().mockResolvedValue({ status: "success", message: "تم الحفظ." });
    render(
      <div>
        <PropertyOwnerEditForm owner={owner} updateOwner={action} />
        <PropertyOwnerArchiveForm ownerId="owner-a" version={2} archiveOwner={action} />
      </div>,
    );

    expect(screen.getByDisplayValue("شركة النخيل")).toBeInTheDocument();
    expect(screen.getByDisplayValue("owner@example.test")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "حفظ التعديل" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "تأكيد الأرشفة" })).toBeInTheDocument();
  });

  it("renders the restore control for an archived owner", () => {
    const restoreOwner = vi.fn().mockResolvedValue({ status: "success", message: "تمت الاستعادة." });
    render(<PropertyOwnerRestoreForm ownerId="owner-a" version={4} restoreOwner={restoreOwner} />);

    expect(screen.getByText("الاستعادة تعيد المالك إلى حالة نشط دون إعادة اختراع أي تعيين.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "استعادة المالك" })).toBeInTheDocument();
  });

  it("wires a valid archive submission to the supplied server action", async () => {
    const archiveOwner = vi.fn().mockResolvedValue({ status: "success", message: "تمت أرشفة المالك." });
    render(<PropertyOwnerArchiveForm ownerId="owner-a" version={2} archiveOwner={archiveOwner} />);
    fireEvent.change(screen.getByRole("textbox", { name: "سبب الأرشفة" }), { target: { value: "انتهى التعاقد" } });
    fireEvent.click(screen.getByRole("button", { name: "تأكيد الأرشفة" }));

    await screen.findByText("تمت أرشفة المالك.");
    expect(archiveOwner).toHaveBeenCalledOnce();
  });
});
