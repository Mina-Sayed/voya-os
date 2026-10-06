import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const stylesheet = readFileSync("src/app/globals.css", "utf8");

function cssVariable(name: string): string {
  const value = stylesheet.match(new RegExp(`--${name}:\\s*(#[0-9a-fA-F]{6})`))?.[1];
  if (!value) throw new Error(`Missing CSS color variable --${name}`);
  return value;
}

function relativeLuminance(hex: string): number {
  const channels = hex.match(/[0-9a-fA-F]{2}/gu)?.map((channel) => Number.parseInt(channel, 16) / 255) ?? [];
  const linear = channels.map((channel) => channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4);
  return 0.2126 * linear[0]! + 0.7152 * linear[1]! + 0.0722 * linear[2]!;
}

function contrastRatio(first: string, second: string): number {
  const values = [relativeLuminance(first), relativeLuminance(second)].sort((a, b) => b - a);
  return (values[0]! + 0.05) / (values[1]! + 0.05);
}

describe("global keyboard focus indicator", () => {
  it("uses a visible outline with at least 3:1 contrast on the main surfaces", () => {
    const outline = stylesheet.match(/button:focus-visible,[\s\S]*?outline:\s*3px solid (var\(--[\w-]+\))/u)?.[1];
    expect(outline).toBeTruthy();
    const token = outline!.match(/var\(--([\w-]+)\)/u)?.[1];
    expect(token).toBeTruthy();
    const focusColor = cssVariable(token!);

    for (const background of [cssVariable("surface"), cssVariable("canvas")]) {
      expect(contrastRatio(focusColor, background)).toBeGreaterThanOrEqual(3);
    }
  });
});
