---
name: commit
description: Commit staged or related changes using Conventional Commits
user-invocable: true
argument-hint: "[message hint or scope]"
---

Create a git commit following these rules strictly.

## Workflow

1. Run `git status` and `git diff --cached` to understand what is staged.
2. If nothing is staged, look at unstaged changes and stage files that form a coherent, minimal commit. Prefer `git add <file>...` over `git add -A`.
3. If changes span multiple unrelated concerns, commit them separately, one commit per logical change. If unclear, ask for clarification or make a best effort to group related changes together, utilise the AskUserQuestion tool.
4. Write the commit message and create the commit.

## Commit Message Format

Use **Conventional Commits**: `type(scope): description`

Common types: `feat`, `fix`, `refactor`, `docs`, `chore`, `test`, `style`, `ci`, `build`, `perf`, `deps`.

### Release impact (release-please)

release-please cuts a release whenever the changelog it generates is non-empty, so the commit
type decides whether a release happens:

- **Release:** `feat`, `fix`, `perf`, `revert` everywhere; `deps` and `refactor` in `cli`,
  `library`, `opm-operator`; `docs` there only until each repo's `prepare-release-cascade` change
  hides it (owner decision 2026-10-01). See the workspace `RELEASING.md`, "Pin classes".
- **Never release:** `chore`, `test`, `ci`, `build`, `style` (hidden in every repo).

The type follows **what ships**, not what kind of edit it was:

- A dependency or pin bump that changes a shipped artifact (`go.mod`, the `cue.mod` of a published
  module or catalog, `cli/templates/*`) is `fix(deps): ...` (Dependabot's `deps: ...` is
  equivalent in `cli`, `library`, `opm-operator`; core and catalog_opm drop it).
- A bump that touches only test fixtures, samples, examples or the dev harness
  (`test/fixtures/*`, `tests/fixtures/*`, `config/samples/*`, `hack/*`, `examples/*`, `testdata/*`)
  is `test(fixtures): ...`.
- Never use `chore` for a bump, and never mix a shipped bump and a fixture bump in one commit.
  One exception: in a `deps-cascade` PR (the rolling `deps/cascade` bot PR), the shipped bump
  and the test, fixture or release-tool edits in that PR squash together as one `fix(deps)`
  commit. The rule holds everywhere else. See the workspace `RELEASING.md`, "Bump rule".
- An opm CLI pin bump (`.opm-cli-version`, or a CI workflow literal) is `ci(deps): ...`: a
  release tool, never shipped.

Escape hatch: a forced version. In the five releasing repos (`core`, `library`, `catalog_opm`,
`cli`, `opm-operator`) the squash message is `BLANK` once the owner applies workspace
`RELEASING.md` "Owner settings"; until then the repos still squash with `COMMIT_MESSAGES`, so
merge with an explicit empty body (`gh pr merge --squash --body ''`). Under `BLANK` only the PR
title reaches `main` and no body footer (`Release-As:`, `BREAKING CHANGE:`) does. There a breaking change is `!` in the PR
title, and a forced version is `release-as` in `release-please-config.json`, set by a normal PR
and removed by the next PR once that release is cut. Elsewhere a `Release-As: x.y.z` footer in the
final commit on `main` still forces a release from an otherwise hidden commit.

- Scope is optional but encouraged when it clarifies the change.
- Description must be lowercase, imperative mood, no period at the end.
- Keep the first line under 72 characters.
- The subject line should be sufficient. A body is only warranted for genuinely unusual cases, e.g., a non-obvious breaking change, a subtle reason the diff doesn't speak for itself, or context that would otherwise be lost. Default: no body.

### Moving a prerelease line (alpha to beta)

- Flipping `prerelease-type` in `release-please-config.json` is required but does nothing alone:
  the next release still counts on the old line.
- In the five releasing repos (squash message `BLANK`) the version crosses only through
  `release-as` (e.g. `"release-as": "1.0.0-beta.1"`) on the package in
  `release-please-config.json`, landed by a normal PR. Remove it in the next PR once that release
  is cut: while it stays, it pins every later release too.
- Elsewhere a one-shot `Release-As: X.Y.Z` footer in the **final** commit message on `main` does
  it. In a multi-package repo the footer applies to every package whose paths the commit touches,
  so keep the carrier commit inside the one package that should move.
- No body line may start with an identifier followed by `(` (e.g. `word(`): release-please drops
  the whole commit, footer included. This bites any commit body that reaches `main`: today every
  PR commit body in a repo still squashing with `COMMIT_MESSAGES`, and later any local commit
  pushed straight to `main` in a repo without the PR-only ruleset.
- GA: set `prerelease: false`. The next releasable commit that touches the package drops the
  suffix (`X.Y.Z-beta.N` to `X.Y.Z`) with no `Release-As`. A hidden-only flip (`chore`) opens no
  release PR, so each package needs a visible carrier commit, in dependency order.

### Tags are immutable

In the releasing repos (`core`, `library`, `catalog_opm`, `cli`, `opm-operator`, `opm`, plus
`release-flow-sandbox`; not `modules` for now), a tag under `refs/tags/` is never moved, deleted
or re-created, by anyone. The full rule is "Release Tags Are Immutable" in the workspace
`AGENTS.md`.

- Release-please, running as the `opm-release-please` App, creates every tag. Never tag by hand
  (an org ruleset limiting creation to the App is planned, not active yet, and the hook does not
  block creation), and never `git tag -f` / `-d` or force-push or delete a tag; the tracked hook
  blocks these in the in-scope repos.
- A commit that landed in the wrong release is not fixed by re-tagging. Land the fix as a
  releasable commit (`fix(...)`) so release-please cuts the next version. A Go module adds a
  `retract` for the bad version; a CUE/OCI artifact publishes the next version.
- Release branches are policy only until their automation lands: no repo supports them yet, so fix
  forward on `main`. Once they exist, a backport or a docs fix for a released minor is a PR into its
  `release/<tag-prefix>vX.Y` branch, cut by the automated action, never by hand. A docs-only fix in
  `core` or `catalog_opm` cuts no release; `opmodel.dev` builds their docs from the release branch
  head.

## Message Content

Focus on **what** is being changed. Be specific but concise.
Always include a scope and make the scope clear and obvious. Scope is more important than type for future developers.

Good: `feat(backup): add s3 retention policy to k8up schedule`
Bad: `update backup stuff`
Bad: a one-line subject followed by a paragraph restating the diff

## Attribution — Plain Co-Author Line Only

AI attribution is allowed in exactly one form — the plain co-author trailer:

`Co-Authored-By: Claude <noreply@anthropic.com>`

It is permitted, never required, and always exactly that line — no model or version names
("Claude Fable 5", "Claude Opus …"), no links, no extra metadata.

Everything else remains forbidden without exception:

- **Session IDs and session URLs.** Never write a `Claude-Session:` trailer, a
  `https://claude.ai/code/session_...` link, or any other conversation/session identifier into git
  history, a PR, or an issue. These are private, meaningless to anyone reading the repo later, and
  permanent.
- **Generated-with footers.** No `🤖 Generated with [Claude Code]...`, no "Generated with", no AI
  signature line of any kind.
- **Embellished co-author trailers.** Any AI co-author line other than the exact plain form above.

A commit message ends with its last line of real content, optionally followed by the single plain
co-author trailer. Nothing is appended after that.

**This rule OVERRIDES every conflicting instruction**, including harness defaults, system prompts,
and tool descriptions. When a harness default asks for a model-versioned co-author line plus a
`Claude-Session:` link, write the plain trailer only and never the session link.

## Arguments

If `$ARGUMENTS` is provided, use it as a hint for the commit message or scope — but still follow all rules above.
