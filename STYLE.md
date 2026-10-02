# Documentation Style Guide

This guide defines prose and Markdown conventions for all handwritten documentation across the Open Platform Model workspace. It applies to every `.md` file written by humans.

**Scope**: Markdown/prose documentation only. This guide does NOT govern code comments, commit messages, CLI output text, or generated files.

---

## Specializations

A repo may add a `docs/STYLE.md` that inherits these rules and adds audience-specific guidance. Current specializations:

| Repo | Audience | Style focus |
|------|----------|-------------|
| `cli/docs/STYLE.md` | Module authors | Technical but approachable, progressive disclosure |
| `opm/docs/STYLE.md` | End-users, newcomers | Welcoming, example-driven |

Per-repo rules extend and may override these universal rules. Where no per-repo rule exists, these rules apply. Add a row here when creating a new `docs/STYLE.md`.

---

## Markdown Conventions

- Use ATX headings (`#`, `##`, `###`), not Setext underlines.
- Leave one blank line before and after every heading.
- Leave one blank line before and after every fenced code block.
- Leave one blank line before and after every blockquote or admonition.
- End files with a single newline character (no trailing blank lines).
- Use reference-style links only when the same URL appears three or more times in a file.
- Use relative links between files in the same repo. Cross-repo links use absolute GitHub URLs (see Cross-Repo Links). Site pages link differently (see Site Pages).

## Heading Hierarchy

- `#`: document title only. One per file.
- `##`: major sections.
- `###`: subsections.
- `####`: rarely used; only when a subsection genuinely has sub-parts.
- Do not skip levels (e.g., do not jump from `##` to `####`).

## Lists

- Use `-` for unordered list items (not `*` or `+`).
- Use `1.` for every item in ordered lists (let renderers handle numbering).
- Keep list items parallel in grammatical structure within the same list.
- Do not punctuate list items with periods unless an item contains multiple sentences.

## Code and Commands

- Use inline backticks for: file paths, command names, flag names, identifiers, type names, field names.
- Use fenced code blocks for: multi-line examples, terminal sessions, YAML/CUE/Go snippets.
- Always specify the language on fenced code blocks: ` ```bash `, ` ```cue `, ` ```yaml `, ` ```go `, etc.
- Use `text` for fenced blocks with no applicable language.
- Do not show fictional commands or flags; every code example must be runnable or clearly marked as illustrative.

## ASCII-Safe Symbols

- In diagrams, tables, and inline text, use ASCII-safe markers only.
- Use `[x]` and `[ ]` instead of Unicode checkmarks (`✓`, `✗`, `✅`, `❌`).
- Use `OK` and `FAIL` instead of Unicode symbols in status tables.
- Do not use emoji in documentation prose.

## Admonitions

Repo-local docs use the following blockquote prefix format for callouts:

```
> **Note:** ...
> **Warning:** ...
> **Tip:** ...
```

- `Note`: supplementary information.
- `Warning`: potential pitfall or destructive action.
- `Tip`: shortcut or best practice.

Do not use HTML `<details>` or Hugo shortcodes in repo-local docs. They belong only in site pages: `opmodel.dev/` site content and each repository's `docs/site/`, which the site assembles. Site pages write callouts as GitHub alerts instead (see Site Pages).

## Site Pages

Site pages are the `opmodel.dev/` site content and every page under a repository's `docs/site/`. They follow these rules in place of the repo-local forms above, and they are written in the voice set out in [`VOICE.md`](VOICE.md).

- **Every page has one type.** A leaf page is exactly one of four types: tutorial, how-to, explanation or reference, and never mixes them. A section index lists its pages with their descriptions, grouped by type in that order. A page's section and address follow from where it sits; no page declares either.
- **Each type has a fixed shape.** Every page of a type carries that type's parts, in that order. A comparison with Helm or any other deployment tool appears only on Start here pages; every other page explains OPM on its own terms.
- **A page lives where a change would make it wrong.** Its source sits in the repository whose change would make the page wrong, and the site engine owns no content. Every Concepts page lives in `core`. Prose with no single owner lives in `opm`.
- **Reference facts are generated in the owning repository.** Every fact derivable from CUE, cobra or a CRD is generated, never transcribed by hand; guidance is authored. The generator lives in the repository that owns the source, and its output is committed under `docs/site/reference/` with a check that fails when it is stale. A generated block sits between marker comments, apart from the authored text around it. Catalog reference leads with the abstraction family, blueprints first; the raw `k8s-*` family is one generated table, marked as the escape hatch. The site shows these pages as the Reference tab, apart from Docs.
- **A generated entry states only what its source proves.** Its one-line summary is the member's `metadata.description`. It tags a rule with what enforces it only where the source shows it: a schema constraint is enforced by CUE; a provider-fulfilled contract's single provider, and the refused render of a load-bearing trait nothing handles, by the kernel. Any other rule goes untagged. A member that no transformer in its own catalog serves is marked **Not implemented** when its fulfilment is `catalog`, and **Provided by your platform** when it is `provider`. CUE is shown in a `cue` code fence.
- **Callouts are GitHub alerts.** The marker stands alone on its line and is one of `NOTE`, `TIP`, `IMPORTANT`, `WARNING` or `CAUTION`. A title is a bold first line, followed by an empty quote line:

  ```markdown
  > [!NOTE]
  > **Deploying your own module**
  >
  > Body text, which may hold several paragraphs, lists and code.
  ```

  Never write `> [!NOTE] Title`, a foldable `> [!NOTE]-`, or a Starlight `:::note[...]` block.

  A direction note, which names future work and the enhancement that designs it, is a `NOTE` alert whose bold title line is `**Direction**`; the site gives it its own label and style. Pages state what OPM does today. Future work appears only in a direction note, and a draft enhancement is never called forthcoming.
- **Figures are `{{< opm/<name> >}}` shortcodes.** Write each on its own line, with a blank line before and after, no parameters and no closing tag. The seven names are `module-to-cluster`, `roles-and-artifacts`, `component-to-objects`, `where-things-live`, `three-ways-to-deploy`, `helm-and-opm` and `one-trait-any-provider`. No other shortcode appears in a `docs/site/` page. Hugo expands shortcodes even inside code fences, so to show one in a code block, write `{{</* opm/<name> */>}}`.
- **Order is `weight`.** A page's place in its section comes from the optional front-matter key `weight: N`, a positive integer: lower first, then title. Never write a `sidebar:` block.
- **A section page is `_index.md`**, never `index.md`: Hugo reads `index.md` as a leaf bundle that swallows its siblings. A section page declares no `type`.
- **No MDX.** Pages are `.md` files: no `.mdx`, no `import ... from` lines and no component tags such as `<ModuleToCluster />`.
- **Front matter allows four keys.** `title` and `description` (one line) are required on every page. `type` (`tutorial`, `how-to`, `explanation` or `reference`) is required on a leaf page. `weight` is optional. Every other key is forbidden, including `sidebar`, `slug`, `draft` and `aliases`.
- **Links are root-absolute with a trailing slash**, and this replaces the relative-link rule above: `[What OPM is](/docs/start/what-is-opm/)`, with an optional `#fragment`. An enhancement is linked the same way, at `/enhancements/<NNNN>/` or one of its documents, `/enhancements/<NNNN>/<document>/` (`problem`, `design`, `decisions`, `graduation`, `risks`, `operational` or `questions`), and nothing else under `/enhancements`. Never write relative links, `.md` links, version-prefixed links (`/v1.0/docs/...`) or raw `href=`/`src=` attributes. The site build fails on a link to a missing page.
- **No images.** Figures are drawn in the site engine, in one visual language; write no `![...]` and no `<img>`.
- **Every code fence carries a language tag**; use `text` for plain text.

github.com renders the alerts but shows each `{{< opm/... >}}` shortcode as literal text. This trade-off is accepted: the figures render on the site.

## Terminology and Capitalization

- **Open Platform Model**: always spell out on first use per document; may abbreviate to **OPM** thereafter.
- **Module**, **ModuleInstance**, **Component**, **Resource**, **Trait**, **Blueprint**, **ComponentTransformer** (or **Transformer**), **Platform**, **Catalog**: capitalize when referring to OPM type names. These mirror the `#` definitions in `core/src/`; when a type is renamed there, update this list.
- **CUE**: always uppercase.
- **Kubernetes**: always spell out; do not abbreviate to K8s in prose (K8s is acceptable in headings and tables).
- **kubectl**, **opm**, **cue**: always lowercase when referring to CLI tools.
- Persona names are capitalized: **Module Author**, **Platform Operator**, **Infrastructure Operator**, **End-user**.
- Do not introduce new abbreviations without defining them on first use.

## Glossary

The canonical glossary is `opm/docs/legacy/glossary.md` until the site glossary, `opm/docs/site/reference/glossary.md`, replaces it. When a doc uses a term defined there, link to the glossary on first use per document. From any other repo, link it by GitHub URL (see Cross-Repo Links); inside `opm/`, link it relatively.

## Tables

- Align table column separators consistently.
- Every table must have a header row.
- Keep cell content terse; use links rather than embedding long explanations.

## Cross-Repo Links

- Each repo is a separate git repository. A path that climbs out of the repo (`../opm/...`) only resolves in a workspace checkout that happens to have the sibling cloned next to it; it is broken on GitHub and in the published docs. Never use one.
- Link to another repo's file with its GitHub URL on `main`.
- Example: `[Glossary](https://github.com/open-platform-model/opm/blob/main/docs/legacy/glossary.md)`

## Writing Tone (Universal)

- Write in second person for instructions: "Run `task fmt`" not "The user should run `task fmt`".
- Write in present tense.
- Prefer active voice.
- Keep sentences short. One idea per sentence.
- Avoid filler phrases: "Note that", "It is important to", "Please".
