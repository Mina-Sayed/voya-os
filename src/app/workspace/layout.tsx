import { WebMCPSiteTools } from "@/features/webmcp/webmcp-site-tools";

/**
 * Renders workspace tools followed by the workspace content.
 *
 * @param children - The workspace content to render.
 * @returns The workspace layout content.
 */
export default function WorkspaceLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <>
      <WebMCPSiteTools />
      {children}
    </>
  );
}
