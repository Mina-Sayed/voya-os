import { WebMCPSiteTools } from "@/features/webmcp/webmcp-site-tools";

export default function WorkspaceLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <>
      <WebMCPSiteTools />
      {children}
    </>
  );
}
