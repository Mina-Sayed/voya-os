"use client";

import { CircleAlert, ImagePlus, LoaderCircle } from "lucide-react";
import { useActionState } from "react";
import { useCommandForm } from "@/features/shared/use-command-form";

export type PropertyImageUploadState = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  message: string;
}>;

export type PropertyImageUploadAction = (
  previousState: PropertyImageUploadState,
  formData: FormData,
) => Promise<PropertyImageUploadState>;

const initialState: PropertyImageUploadState = { status: "idle", message: "" };

export function PropertyImageUploadForm({ propertyId, uploadImage }: Readonly<{ propertyId: string; uploadImage: PropertyImageUploadAction }>) {
  const [state, formAction, isPending] = useActionState(uploadImage, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return (
    <form action={formAction} className="mt-4 border-t border-line pt-4" ref={formRef}>
      <input name="property_id" type="hidden" value={propertyId} />
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <label className="flex cursor-pointer items-center justify-between gap-3 rounded-xl border border-dashed border-[#bfd1cb] bg-[#f8fbf9] px-3 py-3 text-xs font-bold text-harbor" htmlFor={`property-image-${propertyId}`}>
        <span className="inline-flex items-center gap-2"><ImagePlus className="size-4 text-tide" />رفع صورة خاصة</span>
        <span className="text-[10px] font-medium text-muted">JPEG / PNG / WebP · 10MB</span>
      </label>
      <input accept="image/jpeg,image/png,image/webp" className="sr-only" disabled={isPending} id={`property-image-${propertyId}`} name="file" required type="file" />
      <button className="mt-3 inline-flex h-9 items-center justify-center gap-2 rounded-lg bg-harbor px-3 text-[11px] font-bold text-white disabled:opacity-60" disabled={isPending} type="submit">{isPending ? <LoaderCircle className="size-3.5 animate-spin" /> : <ImagePlus className="size-3.5" />}حفظ الصورة</button>
      {state.status !== "idle" ? <p aria-live="polite" className={`mt-2 flex items-center gap-2 text-xs ${state.status === "success" ? "text-tide" : "text-coral"}`}><CircleAlert className="size-3.5" />{state.message}</p> : null}
    </form>
  );
}
