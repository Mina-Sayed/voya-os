"use client";

import { LoaderCircle, UserPlus } from "lucide-react";
import { useRouter } from "next/navigation";
import { useActionState, useEffect } from "react";
import type { InvitationActionState } from "@/app/invite/actions";

const initialState: InvitationActionState = { status: "idle", message: "" };

export function InvitationAcceptForm({ token, action }: Readonly<{
  token: string;
  action: (previousState: InvitationActionState, formData: FormData) => Promise<InvitationActionState>;
}>) {
  const [state, formAction, pending] = useActionState(action, initialState);
  const router = useRouter();

  useEffect(() => {
    if (state.status === "success") router.replace("/workspace");
  }, [router, state.status]);

  return (
    <form action={formAction} className="mt-7 space-y-4">
      <input name="token" type="hidden" value={token} />
      <button className="flex h-13 w-full items-center justify-center gap-2 rounded-2xl bg-harbor px-5 text-sm font-bold text-white transition hover:bg-tide disabled:cursor-not-allowed disabled:opacity-60" disabled={pending} type="submit">
        {pending ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin" /> : <UserPlus aria-hidden="true" className="size-4" />}
        قبول الدعوة وفتح مساحة العمل
      </button>
      {state.status !== "idle" ? <p aria-live="polite" className={`text-xs leading-6 ${state.status === "success" ? "text-tide" : "text-coral"}`}>{state.message}</p> : null}
    </form>
  );
}
