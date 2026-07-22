import { expect, test } from "vitest";
import { resolveLocale } from "./locale";
test("resolves supported locales to their language and writing direction",()=>{expect(resolveLocale("ar")).toEqual({locale:"ar",direction:"rtl"});expect(resolveLocale("en")).toEqual({locale:"en",direction:"ltr"});});
test("falls back to Arabic for an untrusted locale value",()=>{expect(resolveLocale("fr")).toEqual({locale:"ar",direction:"rtl"});});
