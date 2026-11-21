# Publishing the NotchFlow documentation to GitHub Wiki

The Markdown files in `docs/wiki/` are the documentation source of truth. Do not author the same pages directly in GitHub Wiki: a GitHub Wiki is a separate Git repository, and direct edits can drift from code-reviewed product documentation.

## One-time setup

1. In GitHub, open **Repository Settings → General → Features** and enable **Wikis**.
2. Create one initial Wiki page through GitHub’s UI if the Wiki has never been initialized.
3. Clone the separate Wiki repository beside this project:

   ```bash
   git clone https://github.com/sidhxntt/notchflow.wiki.git ../notchflow.wiki
   ```

## Render and publish

From this repository root:

```bash
node scripts/render-github-wiki.mjs ../notchflow.wiki

cd ../notchflow.wiki
git status
git add Home.md Product-Overview.md Features.md Who-NotchFlow-Is-For.md \
  Generic-Mode-and-Agentic-Mode.md Architecture.md Engineering-Challenges.md \
  Engineering-Implementation-Guide.md \
  Technology-Stack.md \
  Privacy-and-Permissions.md Release-Signing-Notarization-DMG-and-ZIP-Delivery.md \
  Updates-and-Versioning.md Development.md Frequently-Asked-Questions.md \
  Wiki-Publishing.md _Sidebar.md _Footer.md
git commit -m "docs: publish NotchFlow Wiki"
git push
```

The renderer writes only the NotchFlow-managed Wiki pages. It does not delete other files from the Wiki clone. Remove obsolete manually authored Wiki pages deliberately.

## Page map

| Repository source | GitHub Wiki page |
| --- | --- |
| `docs/wiki/index.md` | `Home` |
| `docs/wiki/overview.md` | `Product-Overview` |
| `docs/wiki/features.md` | `Features` |
| `docs/wiki/audience.md` | `Who-NotchFlow-Is-For` |
| `docs/wiki/modes.md` | `Generic-Mode-and-Agentic-Mode` |
| `docs/wiki/architecture.md` | `Architecture` |
| `docs/wiki/implementation-guide.md` | `Engineering-Implementation-Guide` |
| `docs/wiki/technology-stack.md` | `Technology-Stack` |
| `docs/wiki/engineering-challenges.md` | `Engineering-Challenges` |
| `docs/wiki/privacy-and-permissions.md` | `Privacy-and-Permissions` |
| `docs/wiki/release-distribution.md` | `Release-Signing-Notarization-DMG-and-ZIP-Delivery` |
| `docs/wiki/updates-and-versioning.md` | `Updates-and-Versioning` |
| `docs/wiki/development.md` | `Development` |
| `docs/wiki/faq.md` | `Frequently-Asked-Questions` |
| `docs/wiki-publishing.md` | `Wiki-Publishing` |

## Maintenance rules

- Update a source page whenever a product or release behavior changes.
- Keep implemented behavior, current verification, and future ideas clearly distinct.
- Never publish credentials, private paths, live API keys, raw incident logs, or user data.
- Render into a disposable directory first when changing the renderer.
- Inspect the generated `Home.md` and `_Sidebar.md` before committing the Wiki repository.
