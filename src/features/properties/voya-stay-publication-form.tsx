"use client";

import { CircleAlert, Globe2, ImagePlus, LoaderCircle, ShieldCheck, XCircle } from "lucide-react";
import { useActionState, useState } from "react";
import { useCommandForm } from "@/features/shared/use-command-form";
import type { PropertyListItem } from "./properties-page";
import type { PropertyMutationAction } from "./property-command-state";

type PublicListingProperty = Pick<PropertyListItem, "id" | "name" | "imageIds">
  & Partial<Pick<PropertyListItem, "city" | "district" | "bedrooms" | "maxGuests" | "marketingDescription" | "amenities">>;

export type VoyaStayPublication = Readonly<{
  id: string;
  slug: string;
  title: string;
  status: "published" | "unpublished";
  version: number;
  description: string;
  areaLabel: string;
  bedrooms: number;
  maxGuests: number;
  amenities: readonly string[];
  pendingMediaCleanup: boolean;
}>;

const initialState = { status: "idle" as const, message: "" };

export function VoyaStayPublicationForm({
  property,
  listing,
  publish,
  unpublish,
  retryCleanup,
}: Readonly<{
  property: PublicListingProperty;
  listing?: VoyaStayPublication;
  publish: PropertyMutationAction;
  unpublish: PropertyMutationAction;
  retryCleanup?: PropertyMutationAction;
}>) {
  const [publishState, publishAction, isPublishing] = useActionState(publish, initialState);
  const [generatedSlug] = useState(() => `stay-${crypto.randomUUID()}`);
  const { formRef: publishFormRef, idempotencyKey: publishIdempotencyKey } = useCommandForm(publishState);
  const [unpublishState, unpublishAction, isUnpublishing] = useActionState(unpublish, initialState);
  const { formRef: unpublishFormRef, idempotencyKey: unpublishIdempotencyKey } = useCommandForm(unpublishState);
  const titleId = `voya-stay-title-${property.id}`;
  const slugId = `voya-stay-slug-${property.id}`;
  const descriptionId = `voya-stay-description-${property.id}`;
  const areaId = `voya-stay-area-${property.id}`;
  const bedroomsId = `voya-stay-bedrooms-${property.id}`;
  const guestsId = `voya-stay-guests-${property.id}`;
  const amenitiesId = `voya-stay-amenities-${property.id}`;

  return (
    <details className="mt-4 rounded-xl border border-[#d4dfda] bg-[#f8fbf9] px-3 py-2">
      <summary className="cursor-pointer text-xs font-bold text-tide">
        {listing?.status === "published" ? "تحديث صفحة VOYA Stay العامة" : "تجهيز للنشر على VOYA Stay"}
      </summary>
      {listing?.status === "published" ? (
        <p className="mt-3 flex items-center gap-2 rounded-lg bg-[#edf8f4] px-3 py-2 text-[11px] font-bold text-tide">
          <Globe2 aria-hidden="true" className="size-4" />
          <span>منشور على VOYA Stay · <bdi dir="ltr">{listing.slug}</bdi></span>
        </p>
      ) : null}

      <form action={publishAction} className="mt-4 grid gap-3 border-t border-line pt-4" ref={publishFormRef}>
        <input name="property_id" type="hidden" value={property.id} />
        <input name="idempotency_key" type="hidden" value={publishIdempotencyKey} />
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="text-xs font-bold text-harbor" htmlFor={titleId}>
            العنوان العام
            <input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={listing?.title ?? property.name} disabled={isPublishing} id={titleId} maxLength={120} name="title" required />
          </label>
          <label className="text-xs font-bold text-harbor" htmlFor={slugId}>
            الرابط العام
            <input className="ltr mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={listing?.slug ?? generatedSlug} disabled={isPublishing} dir="ltr" id={slugId} maxLength={80} name="slug" pattern="[a-z0-9]+(-[a-z0-9]+)*" required />
          </label>
          <label className="text-xs font-bold text-harbor sm:col-span-2" htmlFor={descriptionId}>
            الوصف العام
            <textarea className="mt-1 min-h-20 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 py-2 text-xs leading-6" defaultValue={listing?.description ?? property.marketingDescription ?? ""} disabled={isPublishing} id={descriptionId} maxLength={2500} name="description" required />
          </label>
          <label className="text-xs font-bold text-harbor" htmlFor={areaId}>
            المنطقة المعروضة
            <input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={listing?.areaLabel ?? property.district ?? property.city ?? ""} disabled={isPublishing} id={areaId} maxLength={100} name="area_label" required />
          </label>
          <label className="text-xs font-bold text-harbor" htmlFor={bedroomsId}>
            غرف النوم المنشورة
            <input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={listing?.bedrooms ?? property.bedrooms ?? ""} disabled={isPublishing} id={bedroomsId} max="100" min="0" name="bedrooms" required type="number" />
          </label>
          <label className="text-xs font-bold text-harbor" htmlFor={guestsId}>
            الحد الأقصى للضيوف
            <input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" defaultValue={listing?.maxGuests ?? property.maxGuests ?? ""} disabled={isPublishing} id={guestsId} max="50" min="1" name="max_guests" required type="number" />
          </label>
          <label className="text-xs font-bold text-harbor" htmlFor={amenitiesId}>
            المرافق المعروضة <span className="font-normal text-muted">(افصل بينها بفاصلة)</span>
            <input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={listing?.amenities.join(", ") ?? property.amenities?.join(", ") ?? ""} disabled={isPublishing} id={amenitiesId} maxLength={600} name="amenities" />
          </label>
        </div>

        <fieldset className="rounded-lg border border-line bg-white p-3" disabled={isPublishing}>
          <legend className="px-1 text-xs font-bold text-harbor">اختر الصور العامة صراحةً</legend>
          {property.imageIds.length === 0 ? (
            <p className="py-2 text-[11px] leading-5 text-muted">ارفع صورة خاصة للعقار أولًا، ثم اختر النسخة التي تسمح بعرضها علنًا.</p>
          ) : (
            <div className="grid gap-2 sm:grid-cols-2">
              {property.imageIds.map((imageId, index) => (
                <div className="flex items-center gap-2 rounded-lg bg-canvas px-2.5 py-2 text-[11px] text-ink" key={imageId}>
                  <label className="flex min-w-0 flex-1 items-center gap-2" htmlFor={`voya-stay-image-${property.id}-${index}`}>
                    <input id={`voya-stay-image-${property.id}-${index}`} name="image_id" type="checkbox" value={imageId} />
                    <ImagePlus aria-hidden="true" className="size-3.5 shrink-0 text-tide" />
                    <span>استخدام الصورة {index + 1}</span>
                  </label>
                  <a aria-label={`فتح الصورة الخاصة ${index + 1}`} className="shrink-0 text-tide underline" href={`/api/workspace/properties/${property.id}/images/${imageId}`} rel="noreferrer" target="_blank">معاينة</a>
                </div>
              ))}
            </div>
          )}
        </fieldset>

        <p className="flex items-start gap-2 text-[10px] leading-5 text-muted">
          <ShieldCheck aria-hidden="true" className="mt-0.5 size-3.5 shrink-0 text-tide" />
          راجع العنوان والوصف والمنطقة قبل النشر. لن تنتقل الصور الخاصة؛ سينشر اختيارك نسخ WebP عامة بعد التحويل.
        </p>
        <button className="inline-flex min-h-10 items-center justify-center gap-2 rounded-lg bg-harbor px-4 text-xs font-bold text-white disabled:cursor-not-allowed disabled:opacity-50" disabled={isPublishing || property.imageIds.length === 0} type="submit">
          {isPublishing ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin" /> : <Globe2 aria-hidden="true" className="size-4" />}
          {listing?.status === "published" ? "حفظ التحديث والنشر" : "نشر على VOYA Stay"}
        </button>
        {publishState.status !== "idle" ? <p aria-live="polite" className={`text-xs leading-5 ${publishState.status === "success" ? "text-tide" : "text-coral"}`} role="status">{publishState.status !== "success" ? <CircleAlert aria-hidden="true" className="me-1 inline size-3.5" /> : null}{publishState.message}</p> : null}
      </form>

      {listing?.status === "published" ? (
        <form action={unpublishAction} className="mt-4 border-t border-line pt-3" ref={unpublishFormRef}>
          <input name="listing_id" type="hidden" value={listing.id} />
          <input name="expected_version" type="hidden" value={listing.version} />
          <input name="idempotency_key" type="hidden" value={unpublishIdempotencyKey} />
          <button className="inline-flex min-h-9 items-center gap-2 rounded-lg border border-[#e4cbc5] bg-[#fffaf8] px-3 text-[11px] font-bold text-[#9f493c] disabled:opacity-50" disabled={isUnpublishing} type="submit">
            {isUnpublishing ? <LoaderCircle aria-hidden="true" className="size-3.5 animate-spin" /> : <XCircle aria-hidden="true" className="size-3.5" />}
            إخفاء من VOYA Stay
          </button>
          {unpublishState.status !== "idle" ? <p aria-live="polite" className={`mt-2 text-xs leading-5 ${unpublishState.status === "success" ? "text-tide" : "text-coral"}`} role="status">{unpublishState.message}</p> : null}
        </form>
      ) : null}
      {listing?.pendingMediaCleanup ? <VoyaStayMediaCleanupForm cleanup={retryCleanup ?? noCleanupAction} listing={listing} /> : null}
    </details>
  );
}

async function noCleanupAction(): Promise<Readonly<{ status: "denied"; message: string }>> {
  return { status: "denied", message: "تنظيف الصور العامة غير متاح." };
}

export function VoyaStayMediaCleanupForm({
  listing,
  cleanup,
}: Readonly<{ listing: VoyaStayPublication; cleanup: PropertyMutationAction }>) {
  const [state, formAction, isPending] = useActionState(cleanup, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return (
    <form action={formAction} className="mt-4 border-t border-line pt-3" ref={formRef}>
      <input name="listing_id" type="hidden" value={listing.id} />
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <p className="text-[10px] leading-5 text-[#745b2d]">الإقامة مخفية. ما زالت هناك صورة عامة تنتظر التنظيف.</p>
      <button className="mt-2 inline-flex min-h-9 items-center gap-2 rounded-lg border border-[#ead7a8] bg-[#fff8e9] px-3 text-[11px] font-bold text-[#745b2d] disabled:opacity-50" disabled={isPending} type="submit">
        {isPending ? <LoaderCircle aria-hidden="true" className="size-3.5 animate-spin" /> : <XCircle aria-hidden="true" className="size-3.5" />}
        إعادة محاولة حذف الصور العامة
      </button>
      {state.status !== "idle" ? <p aria-live="polite" className={`mt-2 text-xs leading-5 ${state.status === "success" ? "text-tide" : "text-coral"}`} role="status">{state.message}</p> : null}
    </form>
  );
}
