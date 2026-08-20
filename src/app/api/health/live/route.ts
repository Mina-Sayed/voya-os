import { NextResponse } from "next/server";
import { readReleaseInfo } from "@/lib/release/version";

export const dynamic = "force-dynamic";

export function GET() {
  const release = readReleaseInfo();
  return NextResponse.json({ status: "ok", release_sha: release.commit }, {
    status: 200,
    headers: { "cache-control": "no-store, max-age=0", "x-content-type-options": "nosniff" },
  });
}
