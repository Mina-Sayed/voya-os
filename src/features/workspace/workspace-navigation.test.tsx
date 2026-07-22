import { render, screen } from "@testing-library/react";
import { expect, test } from "vitest";
import { WorkspaceNavigation } from "./workspace-navigation";
test("offers protected entry points for implemented workspaces", () => { render(<WorkspaceNavigation />); expect(screen.getByRole("link", { name: /العملاء المحتملون/ })).toHaveAttribute("href", "/workspace/leads"); expect(screen.getByRole("link", { name: /الإشعارات/ })).toHaveAttribute("href", "/workspace/notifications"); expect(screen.getByRole("link", { name: /الموافقات/ })).toHaveAttribute("href", "/workspace/approvals"); });
