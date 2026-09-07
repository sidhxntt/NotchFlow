#!/usr/bin/env node

/**
 * Render the repository-owned NotchFlow documentation into GitHub Wiki pages.
 * The Wiki is a separate repository; source stays under docs/wiki so it can be
 * reviewed beside product changes. This script intentionally never deletes
 * files from the target Wiki clone.
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, posix, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sourceRoot = resolve(repositoryRoot, "docs");
const outputRoot = process.argv[2] ? resolve(process.argv[2]) : undefined;
const repositoryURL = "https://github.com/sidhxntt/notchflow";

if (!outputRoot) {
  console.error("Usage: node scripts/render-github-wiki.mjs <wiki-directory>");
  process.exit(2);
}

const pages = [
  ["wiki/index.md", "Home.md"],
  ["wiki/overview.md", "Product-Overview.md"],
  ["wiki/features.md", "Features.md"],
  ["wiki/audience.md", "Who-NotchFlow-Is-For.md"],
  ["wiki/modes.md", "Generic-Mode-and-Agentic-Mode.md"],
  ["wiki/architecture.md", "Architecture.md"],
  ["wiki/implementation-guide.md", "Engineering-Implementation-Guide.md"],
  ["wiki/technology-stack.md", "Technology-Stack.md"],
  ["wiki/engineering-challenges.md", "Engineering-Challenges.md"],
  ["wiki/privacy-and-permissions.md", "Privacy-and-Permissions.md"],
  ["wiki/release-distribution.md", "Release-Signing-Notarization-DMG-and-ZIP-Delivery.md"],
  ["wiki/updates-and-versioning.md", "Updates-and-Versioning.md"],
  ["wiki/development.md", "Development.md"],
  ["wiki/faq.md", "Frequently-Asked-Questions.md"],
  ["wiki-publishing.md", "Wiki-Publishing.md"],
  ["wiki/_Sidebar.md", "_Sidebar.md"],
  ["wiki/_Footer.md", "_Footer.md"],
];

const pageNames = new Map(
  pages.map(([source, destination]) => [source, destination.replace(/\.md$/, "")]),
);

function rewriteLinks(markdown, source) {
  return markdown.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (full, text, href) => {
    if (/^(?:https?:|mailto:|#)/i.test(href)) return full;

    const [path, anchor = ""] = href.split("#", 2);
    const targetPath = posix.normalize(posix.join(posix.dirname(source), path));
    const targetPage = pageNames.get(targetPath);
    if (targetPage) {
      return anchor ? `[${text}](${targetPage}#${anchor})` : `[[${targetPage}|${text}]]`;
    }

    const repositoryPath = posix.normalize(posix.join("docs", posix.dirname(source), path));
    if (repositoryPath.startsWith("../")) return full;
    const suffix = anchor ? `#${anchor}` : "";
    return `[${text}](${repositoryURL}/blob/main/${repositoryPath}${suffix})`;
  });
}

await mkdir(outputRoot, { recursive: true });
for (const [source, destination] of pages) {
  const contents = await readFile(resolve(sourceRoot, source), "utf8");
  await writeFile(resolve(outputRoot, destination), rewriteLinks(contents, source));
}

console.log(`Rendered ${pages.length} NotchFlow Wiki pages into ${outputRoot}`);
