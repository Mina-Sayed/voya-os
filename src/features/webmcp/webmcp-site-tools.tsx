"use client";

import { useEffect } from "react";
import {
  registerVoyaSiteTools,
  type VoyaWebMCPInvoker,
  type WebMCPModelContext,
} from "./site-tools";

type WebMCPDocument = Document & Readonly<{
  modelContext?: WebMCPModelContext;
}>;

export const invokeWebMCPTool: VoyaWebMCPInvoker = async (tool, input, signal) => {
  const response = await fetch("/api/workspace/webmcp", {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify({ tool, args: input }),
    signal,
  });

  const payload = (await response.json().catch(() => ({ error: "invalid_response" }))) as Record<string, unknown>;
  if (!response.ok) {
    const error = typeof payload.error === "string" ? payload.error : "site_tool_failed";
    throw new Error(`VOYA site tool failed: ${error}`);
  }
  return payload;
};

export function WebMCPSiteTools() {
  useEffect(() => {
    const modelContext = (document as WebMCPDocument).modelContext;
    if (!modelContext) return;

    const controller = new AbortController();
    void registerVoyaSiteTools(modelContext, invokeWebMCPTool, controller.signal).catch((error: unknown) => {
      if (!controller.signal.aborted) {
        console.error("Failed to register VOYA WebMCP site tools", error);
      }
    });

    return () => controller.abort();
  }, []);

  return null;
}
