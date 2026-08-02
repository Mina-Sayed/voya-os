"use client";

import { useEffect, useRef, useState } from "react";

export function useCommandForm(state: Readonly<{ status: string }>) {
  const formRef = useRef<HTMLFormElement>(null);
  const handledState = useRef(state);
  const [idempotencyKey, setIdempotencyKey] = useState(() => crypto.randomUUID());

  useEffect(() => {
    if (handledState.current === state) return;
    handledState.current = state;
    if (state.status !== "success") return;
    formRef.current?.reset();
    // A successful server result starts the next command with a new key.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setIdempotencyKey(crypto.randomUUID());
  }, [state]);

  return { formRef, idempotencyKey } as const;
}
