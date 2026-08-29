import { cleanup } from "@testing-library/react";
import "@testing-library/jest-dom/vitest";
import { afterEach, beforeEach } from "vitest";

function ensureLocalStorage(): void {
  const hasUsableStorage = (() => {
    try {
      return typeof window !== "undefined" && typeof window.localStorage !== "undefined" && typeof window.localStorage.getItem === "function" && typeof window.localStorage.setItem === "function";
    } catch {
      return false;
    }
  })();
  if (hasUsableStorage) return;
  const store = new Map<string, string>();
  const polyfill = {
    getItem(key: string) {
      return store.has(key) ? store.get(key)! : null;
    },
    setItem(key: string, value: string) {
      store.set(key, String(value));
    },
    removeItem(key: string) {
      store.delete(key);
    },
    clear() {
      store.clear();
    },
    key(index: number) {
      return Array.from(store.keys())[index] ?? null;
    },
    get length() {
      return store.size;
    },
  } as unknown as Storage;
  try {
    Object.defineProperty(window, "localStorage", { value: polyfill, configurable: true, writable: true });
  } catch {
    (window as unknown as Record<string, unknown>).localStorage = polyfill;
  }
}

beforeEach(() => {
  ensureLocalStorage();
});

afterEach(() => {
  cleanup();
  try {
    window.localStorage.clear();
  } catch {
    // jsdom opaque origin fallback already handled by polyfill
  }
});
