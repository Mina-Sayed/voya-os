"use client";

import { useEffect, useRef, useState } from "react";

type CommandFormState = Readonly<{
  status: string;
  resetIdempotencyKey?: boolean;
}>;

export function useCommandForm(state: CommandFormState) {
  const formRef = useRef<HTMLFormElement>(null);
  const handledState = useRef(state);
  const [idempotencyKey, setIdempotencyKey] = useState(() => crypto.randomUUID());

  useEffect(() => {
    if (handledState.current === state) return;
    handledState.current = state;

    const succeeded = state.status === "success";
    if (!succeeded && state.resetIdempotencyKey !== true) return;

    if (succeeded) formRef.current?.reset();
    // A completed command or an explicitly poisoned key starts a fresh attempt.
    // Retry/denied/ordinary validation failures keep the existing key.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setIdempotencyKey(crypto.randomUUID());
  }, [state]);

  return { formRef, idempotencyKey } as const;
}
