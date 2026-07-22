import { render, screen } from "@testing-library/react";
import { expect, test } from "vitest";
import { WorkspaceNavigation } from "./workspace-navigation";
test("offers protected entry points for implemented workspaces", () => { render(<WorkspaceNavigation />); expect(screen.getByRole("link", { name: /العملاء المحتملون/ })).toHaveAttribute("href", "/workspace/leads"); expect(screen.getByRole("link", { name: /العقارات/ })).toHaveAttribute("href", "/workspace/properties"); });
