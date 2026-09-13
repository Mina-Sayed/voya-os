"use client";

import { useEffect, useRef, useState } from "react";

export function useCommandForm(state: Readonly<{ status: string }>) {
  const formRef = useRef<HTMLFormElement>(null);
  const handledState = useRef(state);
  const [idempotencyKey, setIdempotencyKey] = useState(() => crypto.randomUUID());

  useEffect(() => {
    if (handledState.current === state) return;
    handledState.current = state;
    // Rotate after a terminal answer so a poisoned key (same key, edited
    // payload → 23505 invalid) cannot trap the next attempt in a loop.
    // Retry/denied keep the key so a same-payload retry still dedupes.
    // Only a success clears the form; an invalid answer preserves the user's
    // edits and only hands them a fresh key for the correction.
    if (state.status !== "success" && state.status !== "invalid") return;
    if (state.status === "success") formRef.current?.reset();
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setIdempotencyKey(crypto.randomUUID());
  }, [state]);

  return { formRef, idempotencyKey } as const;
}
