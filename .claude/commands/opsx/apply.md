---
name: "OPSX: Apply"
description: Route to a repo and implement tasks from one of its OpenSpec changes
category: Workflow
tags: [workflow, artifacts, experimental, router]
---

Implement tasks from an OpenSpec change, in the repo that owns the change.

**Input**: Optionally a repo and/or change name (e.g., `/opsx:apply add-auth`, `/opsx:apply cli add-auth`). If omitted, infer from conversation context; if vague or ambiguous you MUST prompt for available changes in the resolved repo.

## Routing (always)

This command runs at the workspace root, which has **no OpenSpec skills of its own**. It is a router: every run must resolve to exactly one repo and execute that repo's local skill. Never improvise the workflow from memory.

1. **Resolve the repo.** In order of precedence:
   - An explicit repo given as the first argument (`/opsx:apply <repo> ...`) or as a leading path segment.
   - A change name that exists under exactly one `<repo>/openspec/changes/<name>/` (search all repos; if it exists in several, ask).
   - The repo the conversation is already working in.
   - Otherwise use the Routing table in the root `CLAUDE.md`; if the target is still ambiguous, **ask** (one question beats working in the wrong repo). Never guess.

   Only repos with a `<repo>/openspec/` directory **and** a `<repo>/.claude/skills/openspec-apply-change/SKILL.md` qualify. Discover these from the filesystem on every run; do not hardcode the list. A repo with an `openspec/` directory but no skill is not a valid target: say so and stop.

2. **Enter the repo.** Work from `<repo>/` as the working directory, so `openspec` CLI calls and relative paths resolve against that repo's `openspec/`. Read the repo's `CLAUDE.md` (and `CONSTITUTION.md` / `openspec/config.yaml` where present) and check the branch against the Branch Model before proceeding.

3. **Execute the repo-local skill.** Read `<repo>/.claude/skills/openspec-apply-change/SKILL.md` and follow it exactly as if it had been invoked, passing along the remaining arguments (the change name). The root Skill tool cannot see repo-local skills, so load the file directly.

4. **State which repo and skill ran** at the start of your reply (`Repo: core, skill: openspec-apply-change`).

## After routing

- Create a working branch **in the resolved repo** before editing (each repo is its own git repository; the workspace root is not one).

## Guardrails

- **One repo per run.** Every OpenSpec change lives in a single repo's `openspec/`; never create or edit artifacts at the workspace root or across repos in one invocation.
- **Repo rules win.** Once inside a repo, its `CLAUDE.md` is the source of truth; the root `CLAUDE.md` only did the routing.
- **Ask before guessing the repo.** Wrong repo means wasted work.
