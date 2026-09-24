---
name: "OPSX: New"
description: Route to a repo and start a new change using the experimental artifact workflow (OPSX)
category: Workflow
tags: [workflow, artifacts, experimental, router]
---

Start a new change using the experimental artifact-driven approach, inside the repo the change belongs to.

**Input**: Optionally a repo, then either a change name (kebab-case) or a description of what the user wants to build (e.g., `/opsx:new core add-trait-defaults`, `/opsx:new modules sonarr-metrics`).

## Routing (always)

This command runs at the workspace root, which has **no OpenSpec skills of its own**. It is a router: every run must resolve to exactly one repo and execute that repo's local skill. Never improvise the workflow from memory.

1. **Resolve the repo.** In order of precedence:
   - An explicit repo given as the first argument (`/opsx:new <repo> ...`) or as a leading path segment.
   - The repo the described feature lands in, per the Routing table in root `AGENTS.md`. A feature that spans repos needs one change per repo (and usually an `enhancements/` entry first); ask which to start with.
   - The repo the conversation is already working in.
   - Otherwise use the Routing table in the root `AGENTS.md`; if the target is still ambiguous, **ask** (one question beats working in the wrong repo). Never guess.

   Only repos with a `<repo>/openspec/` directory **and** a `<repo>/.claude/skills/openspec-new-change/SKILL.md` qualify. Discover these from the filesystem on every run; do not hardcode the list. A repo with an `openspec/` directory but no skill is not a valid target: say so and stop.

2. **Enter the repo.** Work from `<repo>/` as the working directory, so `openspec` CLI calls and relative paths resolve against that repo's `openspec/`. Read the repo's `AGENTS.md` (and `CONSTITUTION.md` / `openspec/config.yaml` where present) and check the branch against the Branch Model before proceeding.

3. **Execute the repo-local skill.** Read `<repo>/.claude/skills/openspec-new-change/SKILL.md` and follow it exactly as if it had been invoked, passing along the remaining arguments (the change name or description). The root Skill tool cannot see repo-local skills, so load the file directly.

4. **State which repo and skill ran** at the start of your reply (`Repo: core, skill: openspec-new-change`).

## Guardrails

- **One repo per run.** Every OpenSpec change lives in a single repo's `openspec/`; never create or edit artifacts at the workspace root or across repos in one invocation.
- **Repo rules win.** Once inside a repo, its `AGENTS.md` is the source of truth; the root `AGENTS.md` only did the routing.
- **Ask before guessing the repo.** Wrong repo means wasted work.
