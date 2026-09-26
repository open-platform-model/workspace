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
- Use relative links between files in the same repo. Cross-repo links use absolute GitHub URLs (see Cross-Repo Links).

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

Use the following blockquote prefix format for callouts:

```
> **Note:** ...
> **Warning:** ...
> **Tip:** ...
```

- `Note`: supplementary information.
- `Warning`: potential pitfall or destructive action.
- `Tip`: shortcut or best practice.

Do not use HTML `<details>` or Starlight components in repo-local docs. They belong only in site pages: `opmodel.dev/` site content and each repository's `docs/site/`, which the site assembles.

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
