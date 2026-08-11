import { access, readdir, readFile, realpath, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { basename, dirname, isAbsolute, relative, resolve } from "node:path";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const DEFAULT_ROOT = resolve(dirname(SCRIPT_PATH), "..");

export const MEMORY_FILES = [
  "PROJECT.md",
  "ARCHITECTURE.md",
  "DOMAIN_RULES.md",
  "DATA_MODEL.md",
  "SECURITY.md",
  "INTEGRATIONS.md",
  "SOURCES_OF_TRUTH.md",
  "CURRENT_STATE.md",
  "KNOWN_ISSUES.md",
  "GLOSSARY.md",
  "MAINTENANCE.md",
];

const REQUIRED_FILES = [
  "AGENTS.md",
  "src/AGENTS.md",
  "supabase/AGENTS.md",
  "docs/memory/INDEX.md",
  "docs/adr/INDEX.md",
  ...MEMORY_FILES.map((file) => `docs/memory/${file}`),
];

const OPTIONAL_AGENT_FILES = ["docs/AGENTS.md", ".codex/AGENTS.md"];
const LEGACY_MEMORY_FILES = ["ADR_INDEX.md"];

function formatError(message) {
  return `project-memory: ${message}`;
}

async function exists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function isFile(path) {
  try {
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}

async function assertRealPathInside(rootDir, targetPath, description) {
  const [rootRealPath, targetRealPath] = await Promise.all([
    realpath(rootDir),
    realpath(targetPath),
  ]);
  const escaped = relative(rootRealPath, targetRealPath);
  if (escaped === ".." || escaped.startsWith(`..${requirePathSeparator()}`) || isAbsolute(escaped)) {
    throw new Error(formatError(`${description} resolves outside repository: ${targetPath}`));
  }
}

function extractMarkdownLinks(content) {
  const links = [];
  const pattern = /\[[^\]]*\]\((<[^>]+>|[^)\s]+)(?:\s+[^)]*)?\)/g;
  let match;
  while ((match = pattern.exec(content)) !== null) {
    let target = match[1];
    if (target.startsWith("<") && target.endsWith(">")) {
      target = target.slice(1, -1);
    }
    links.push(target);
  }
  return links;
}

function isExternalLink(target) {
  return /^(?:https?:|mailto:|tel:|data:|#)/i.test(target);
}

function resolveRepositoryLink(rootDir, sourcePath, target) {
  const withoutFragment = target.split(/[?#]/, 1)[0];
  if (!withoutFragment || isExternalLink(target)) return null;
  if (isAbsolute(withoutFragment)) {
    throw new Error(formatError(`${sourcePath} contains an absolute link: ${target}`));
  }

  const absoluteTarget = resolve(dirname(resolve(rootDir, sourcePath)), withoutFragment);
  const escaped = relative(resolve(rootDir), absoluteTarget);
  if (escaped === ".." || escaped.startsWith(`..${requirePathSeparator()}`) || isAbsolute(escaped)) {
    throw new Error(formatError(`${sourcePath} link escapes repository: ${target}`));
  }
  return { relativePath: escaped || ".", absolutePath: absoluteTarget };
}

function requirePathSeparator() {
  return process.platform === "win32" ? "\\" : "/";
}

async function validateLinks(rootDir, relativePath, content, errors) {
  for (const target of extractMarkdownLinks(content)) {
    if (isExternalLink(target)) continue;
    try {
      const resolvedLink = resolveRepositoryLink(rootDir, relativePath, target);
      if (!resolvedLink) continue;
      if (!(await exists(resolvedLink.absolutePath))) {
        errors.push(formatError(`${relativePath} links to missing path: ${target}`));
      } else {
        await assertRealPathInside(rootDir, resolvedLink.absolutePath, `${relativePath} link`);
      }
    } catch (error) {
      errors.push(error instanceof Error ? error.message : String(error));
    }
  }
}

function validateMermaid(relativePath, content, errors) {
  const lines = content.split(/\r?\n/);
  let mermaidOpen = false;
  for (const line of lines) {
    if (/^\s*```(?:text|ascii|dot)\s*$/i.test(line)) {
      errors.push(formatError(`${relativePath} uses a non-Mermaid diagram fence`));
    }
    if (/^\s*```mermaid\s*$/i.test(line)) mermaidOpen = !mermaidOpen;
    else if (mermaidOpen && /^\s*```\s*$/.test(line)) mermaidOpen = false;
  }
  if (mermaidOpen) errors.push(formatError(`${relativePath} has an unbalanced Mermaid fence`));
}

function countLinksToFiles(rootDir, sourcePath, content, directory) {
  const links = [];
  for (const target of extractMarkdownLinks(content)) {
    if (isExternalLink(target)) continue;
    const resolvedLink = resolveRepositoryLink(rootDir, sourcePath, target);
    if (!resolvedLink || dirname(resolvedLink.relativePath) !== directory) continue;
    links.push(basename(resolvedLink.relativePath));
  }
  return links;
}

function assertExactlyOnce(label, expected, actual, errors) {
  const expectedSet = new Set(expected);
  const actualCounts = new Map();
  for (const value of actual) actualCounts.set(value, (actualCounts.get(value) ?? 0) + 1);
  for (const value of expectedSet) {
    if ((actualCounts.get(value) ?? 0) !== 1) {
      errors.push(formatError(`${label} must list ${value} exactly once`));
    }
  }
  for (const value of actualCounts.keys()) {
    if (!expectedSet.has(value)) errors.push(formatError(`${label} lists unexpected entry: ${value}`));
  }
}

async function readRequired(rootDir, relativePath, errors) {
  const absolutePath = resolve(rootDir, relativePath);
  if (!(await isFile(absolutePath))) {
    errors.push(formatError(`missing required file: ${relativePath}`));
    return null;
  }
  try {
    await assertRealPathInside(rootDir, absolutePath, relativePath);
  } catch (error) {
    errors.push(error instanceof Error ? error.message : String(error));
    return null;
  }
  const content = await readFile(absolutePath, "utf8");
  if (!content.trim()) errors.push(formatError(`required file is empty: ${relativePath}`));
  return content;
}

async function validateAgentRouting(rootDir, errors) {
  const paths = ["AGENTS.md", "src/AGENTS.md", "supabase/AGENTS.md"];
  for (const relativePath of OPTIONAL_AGENT_FILES) {
    if (await isFile(resolve(rootDir, relativePath))) paths.push(relativePath);
  }
  for (const relativePath of paths) {
    const content = await readRequired(rootDir, relativePath, errors);
    if (!content) continue;
    let routesToMemory = false;
    for (const target of extractMarkdownLinks(content)) {
      if (isExternalLink(target)) continue;
      try {
        const resolvedLink = resolveRepositoryLink(rootDir, relativePath, target);
        if (resolvedLink?.relativePath === "docs/memory/INDEX.md") routesToMemory = true;
      } catch {
        // The normal link validator below reports the precise path failure.
      }
    }
    if (!routesToMemory) errors.push(formatError(`${relativePath} must route agents to docs/memory/INDEX.md`));
    await validateLinks(rootDir, relativePath, content, errors);
  }
}

async function validateMemoryIndex(rootDir, errors) {
  const relativePath = "docs/memory/INDEX.md";
  const content = await readRequired(rootDir, relativePath, errors);
  if (!content) return;
  const directory = "docs/memory";
  let links;
  try {
    links = countLinksToFiles(rootDir, relativePath, content, directory);
  } catch (error) {
    errors.push(error instanceof Error ? error.message : String(error));
    links = [];
  }

  const entries = await readdir(resolve(rootDir, directory), { withFileTypes: true });
  const expected = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".md") && entry.name !== "INDEX.md")
    .map((entry) => entry.name)
    .sort();
  assertExactlyOnce("docs/memory/INDEX.md", expected, links, errors);
}

async function validateAdrIndex(rootDir, errors) {
  const relativePath = "docs/adr/INDEX.md";
  const content = await readRequired(rootDir, relativePath, errors);
  if (!content) return;
  let links;
  try {
    links = countLinksToFiles(rootDir, relativePath, content, "docs/adr");
  } catch (error) {
    errors.push(error instanceof Error ? error.message : String(error));
    links = [];
  }

  const entries = await readdir(resolve(rootDir, "docs/adr"), { withFileTypes: true });
  const adrFiles = entries
    .filter((entry) => entry.isFile() && /^ADR-\d+-[^/]+\.md$/.test(entry.name))
    .map((entry) => entry.name)
    .sort();
  assertExactlyOnce("docs/adr/INDEX.md", adrFiles, links, errors);

  const identifiers = new Map();
  for (const file of adrFiles) {
    const identifier = file.match(/^ADR-(\d+)-/)[1];
    const prior = identifiers.get(identifier) ?? [];
    prior.push(file);
    identifiers.set(identifier, prior);
  }
  for (const [identifier, files] of identifiers) {
    if (files.length > 1) {
      errors.push(formatError(`duplicate ADR identifier ${identifier}: ${files.join(", ")}`));
    }
  }
}

async function validateProjectMemory(rootDir = DEFAULT_ROOT) {
  const resolvedRoot = resolve(rootDir);
  const errors = [];

  for (const relativePath of REQUIRED_FILES) {
    const content = await readRequired(resolvedRoot, relativePath, errors);
    if (!content) continue;
    if (!content.split(/\r?\n/).some((line) => /^#\s+\S/.test(line))) {
      errors.push(formatError(`${relativePath} must contain a level-one heading`));
    }
    await validateLinks(resolvedRoot, relativePath, content, errors);
    if (relativePath.startsWith("docs/memory/")) validateMermaid(relativePath, content, errors);
  }

  for (const legacyFile of LEGACY_MEMORY_FILES) {
    const relativePath = `docs/memory/${legacyFile}`;
    if (!(await isFile(resolve(resolvedRoot, relativePath)))) continue;
    try {
      await assertRealPathInside(resolvedRoot, resolve(resolvedRoot, relativePath), relativePath);
    } catch (error) {
      errors.push(error instanceof Error ? error.message : String(error));
      continue;
    }
    const content = await readFile(resolve(resolvedRoot, relativePath), "utf8");
    await validateLinks(resolvedRoot, relativePath, content, errors);
    validateMermaid(relativePath, content, errors);
  }

  const currentState = await readRequired(resolvedRoot, "docs/memory/CURRENT_STATE.md", errors);
  if (currentState && !/^\s*(?:\*\*)?Last verified:\*?\*?\s*\d{4}-\d{2}-\d{2}\s*$/m.test(currentState)) {
    errors.push(formatError("docs/memory/CURRENT_STATE.md must contain Last verified: YYYY-MM-DD"));
  }

  await validateAgentRouting(resolvedRoot, errors);
  await validateMemoryIndex(resolvedRoot, errors);
  await validateAdrIndex(resolvedRoot, errors);

  return { valid: errors.length === 0, errors };
}

export { validateProjectMemory };

function parseRootArgument(argv) {
  const index = argv.indexOf("--root");
  if (index === -1) return DEFAULT_ROOT;
  const value = argv[index + 1];
  if (!value) throw new Error("--root requires a directory path");
  return resolve(value);
}

if (resolve(process.argv[1] ?? "") === SCRIPT_PATH) {
  try {
    const rootDir = parseRootArgument(process.argv.slice(2));
    const result = await validateProjectMemory(rootDir);
    if (!result.valid) {
      for (const error of result.errors) console.error(error);
      process.exitCode = 1;
    } else {
      console.log(`Project memory validation passed (${REQUIRED_FILES.length} required files checked).`);
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
