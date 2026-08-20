import { NextResponse } from "next/server";
import { readReleaseInfo } from "@/lib/release/version";

export const dynamic = "force-dynamic";

export function GET() {
  return NextResponse.json(readReleaseInfo(), {
    status: 200,
    headers: { "cache-control": "no-store, max-age=0", "x-content-type-options": "nosniff" },
  });
}
