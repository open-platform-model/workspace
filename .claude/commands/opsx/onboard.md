---
name: "OPSX: Onboard"
description: Route to a repo and walk through a complete OpenSpec workflow cycle with narration
category: Workflow
tags: [workflow, onboarding, tutorial, learning, router]
---

Guide the user through a first complete OpenSpec workflow cycle in one repo. This is a teaching experience: real work in that repo's codebase, with each step explained. The repo's skill owns the tutorial script, phases, and command reference.

**Input**: Optionally a repo (e.g., `/opsx:onboard cli`). If omitted, ask which repo to onboard in; the tutorial picks a small real task from that repo, so the choice matters.

## Routing (always)

This command runs at the workspace root, which has **no OpenSpec skills of its own**. It is a router: every run must resolve to exactly one repo and execute that repo's local skill. Never improvise the workflow from memory.

1. **Resolve the repo.** In order of precedence:
   - An explicit repo given as the first argument (`/opsx:onboard <repo> ...`) or as a leading path segment.
   - The repo the user wants to learn the workflow in.
   - The repo the conversation is already working in.
   - Otherwise use the Routing table in the root `CLAUDE.md`; if the target is still ambiguous, **ask** (one question beats working in the wrong repo). Never guess.

   Only repos with a `<repo>/openspec/` directory **and** a `<repo>/.claude/skills/openspec-onboard/SKILL.md` qualify. Discover these from the filesystem on every run; do not hardcode the list. A repo with an `openspec/` directory but no skill is not a valid target: say so and stop.

2. **Enter the repo.** Work from `<repo>/` as the working directory, so `openspec` CLI calls and relative paths resolve against that repo's `openspec/`. Read the repo's `CLAUDE.md` (and `CONSTITUTION.md` / `openspec/config.yaml` where present) and check the branch against the Branch Model before proceeding.

3. **Execute the repo-local skill.** Read `<repo>/.claude/skills/openspec-onboard/SKILL.md` and follow it exactly as if it had been invoked, passing along the remaining arguments. The root Skill tool cannot see repo-local skills, so load the file directly.

4. **State which repo and skill ran** at the start of your reply (`Repo: core, skill: openspec-onboard`).

## Guardrails

- **One repo per run.** Every OpenSpec change lives in a single repo's `openspec/`; never create or edit artifacts at the workspace root or across repos in one invocation.
- **Repo rules win.** Once inside a repo, its `CLAUDE.md` is the source of truth; the root `CLAUDE.md` only did the routing.
- **Ask before guessing the repo.** Wrong repo means wasted work.
