"use client";

import { CircleAlert, LoaderCircle, Save } from "lucide-react";
import { useActionState } from "react";
import { useCommandForm } from "@/features/shared/use-command-form";
import type { PropertyListItem } from "./properties-page";
import type { PropertyMutationAction } from "./property-command-state";

const initialState = { status: "idle" as const, message: "" };

export function PropertyEditForm({ property, updateProperty }: Readonly<{ property: PropertyListItem; updateProperty: PropertyMutationAction }>) {
  const [state, formAction, isPending] = useActionState(updateProperty, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return (
    <form action={formAction} className="mt-4 grid gap-3 border-t border-line pt-4" ref={formRef}>
      <input name="property_id" type="hidden" value={property.id} />
      <input name="expected_version" type="hidden" value={property.version} />
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="text-xs font-bold text-harbor">الرمز<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={property.code} disabled={isPending} name="code" required /></label>
        <label className="text-xs font-bold text-harbor">الاسم<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={property.name} disabled={isPending} name="name" required /></label>
        <label className="text-xs font-bold text-harbor">المنطقة الزمنية<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={property.timezone} disabled={isPending} name="timezone" required dir="ltr" /></label>
        <label className="text-xs font-bold text-harbor">الحالة<select className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={property.status === "archived" ? "inactive" : property.status} disabled={isPending} name="status"><option value="active">نشط</option><option value="inactive">غير نشط</option></select></label>
        <label className="text-xs font-bold text-harbor">العنوان<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={property.address ?? ""} disabled={isPending} name="address" /></label>
        <label className="text-xs font-bold text-harbor">المدينة<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={property.city ?? ""} disabled={isPending} name="city" /></label>
        <label className="text-xs font-bold text-harbor">رقم الوحدة<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={property.unitLabel ?? ""} disabled={isPending} name="unit_label" /></label>
        <label className="text-xs font-bold text-harbor">غرف النوم<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={property.bedrooms ?? ""} disabled={isPending} min="0" name="bedrooms" type="number" /></label>
        <label className="text-xs font-bold text-harbor">الحد الأقصى للضيوف<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={property.maxGuests ?? ""} disabled={isPending} min="1" name="max_guests" type="number" /></label>
        <label className="text-xs font-bold text-harbor">الحمامات<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={property.bathrooms ?? ""} disabled={isPending} min="0" name="bathrooms" type="number" /></label>
        <label className="text-xs font-bold text-harbor">المساحة بالمتر<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={property.areaSqm ?? ""} disabled={isPending} min="0.01" name="area_sqm" step="0.01" type="number" /></label>
        <label className="text-xs font-bold text-harbor">الحي<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={property.district ?? ""} disabled={isPending} name="district" /></label>
        <label className="text-xs font-bold text-harbor">الطابق<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={property.floor ?? ""} disabled={isPending} name="floor" /></label>
        <label className="text-xs font-bold text-harbor">حالة الفرش<select className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={property.furnished === null || property.furnished === undefined ? "" : String(property.furnished)} disabled={isPending} name="furnished"><option value="">غير محدد</option><option value="true">مفروشة</option><option value="false">غير مفروشة</option></select></label>
        <label className="text-xs font-bold text-harbor">السعر اليومي<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={property.dailyPrice ?? ""} disabled={isPending} min="0" name="daily_price" step="0.01" type="number" /></label>
        <label className="text-xs font-bold text-harbor">السعر الأسبوعي<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={property.weeklyPrice ?? ""} disabled={isPending} min="0" name="weekly_price" step="0.01" type="number" /></label>
        <label className="text-xs font-bold text-harbor">السعر الشهري<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={property.monthlyPrice ?? ""} disabled={isPending} min="0" name="monthly_price" step="0.01" type="number" /></label>
        <label className="text-xs font-bold text-harbor">العملة<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs uppercase" defaultValue={property.currency ?? ""} disabled={isPending} maxLength={3} name="currency" /></label>
        <label className="text-xs font-bold text-harbor">أقل مدة إقامة<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={property.minimumStayNights ?? ""} disabled={isPending} min="1" name="minimum_stay_nights" type="number" /></label>
        <label className="text-xs font-bold text-harbor sm:col-span-2">المرافق<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={property.amenities?.join(", ") ?? ""} disabled={isPending} name="amenities" /></label>
        <label className="text-xs font-bold text-harbor sm:col-span-2">الوصف التسويقي<textarea className="mt-1 min-h-20 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 py-2 text-xs" defaultValue={property.marketingDescription ?? ""} disabled={isPending} name="marketing_description" /></label>
        <label className="text-xs font-bold text-harbor sm:col-span-2">ملاحظات التشغيل<textarea className="mt-1 min-h-20 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 py-2 text-xs" defaultValue={property.operationalNotes ?? ""} disabled={isPending} name="operational_notes" /></label>
      </div>
      <div className="flex flex-wrap gap-4 text-xs font-semibold text-muted"><label className="inline-flex items-center gap-2"><input defaultChecked={property.rentDaily || property.dailyPrice !== null && property.dailyPrice !== undefined} disabled={isPending} name="rent_daily" type="checkbox" value="true" />إيجار يومي</label><label className="inline-flex items-center gap-2"><input defaultChecked={property.rentWeekly || property.weeklyPrice !== null && property.weeklyPrice !== undefined} disabled={isPending} name="rent_weekly" type="checkbox" value="true" />إيجار أسبوعي</label><label className="inline-flex items-center gap-2"><input defaultChecked={property.rentMonthly || property.monthlyPrice !== null && property.monthlyPrice !== undefined} disabled={isPending} name="rent_monthly" type="checkbox" value="true" />إيجار شهري</label></div>
      <button className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-harbor px-4 text-xs font-bold text-white disabled:opacity-60" disabled={isPending} type="submit">{isPending ? <LoaderCircle className="size-3.5 animate-spin" /> : <Save className="size-3.5" />}حفظ التعديل</button>
      {state.status !== "idle" ? <p aria-live="polite" className={`flex items-center gap-2 text-xs ${state.status === "success" ? "text-tide" : "text-coral"}`}>{state.status === "success" ? <Save className="size-3.5" /> : <CircleAlert className="size-3.5" />}{state.message}</p> : null}
    </form>
  );
}
