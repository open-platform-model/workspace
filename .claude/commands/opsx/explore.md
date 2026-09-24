---
name: "OPSX: Explore"
description: "Route to a repo and enter explore mode: think through ideas, investigate problems, clarify requirements"
category: Workflow
tags: [workflow, explore, experimental, thinking, router]
---

Enter explore mode inside one repo. Think deeply. Visualize freely. Follow the conversation wherever it goes.

**IMPORTANT: Explore mode is for thinking, not implementing.** You may read files, search code, and investigate the codebase, but you must NEVER write code or implement features. If the user asks you to implement something, remind them to exit explore mode first and create a change proposal. You MAY create OpenSpec artifacts (proposals, designs, specs) in the resolved repo if the user asks; that is capturing thinking, not implementing.

**Input**: Optionally a repo and/or a topic (e.g., `/opsx:explore library matcher edge cases`). A cross-repo topic is a design-intent question: route it to `enhancements/` conventions instead of OpenSpec, or ask which repo to anchor the exploration in.

## Routing (always)

This command runs at the workspace root, which has **no OpenSpec skills of its own**. It is a router: every run must resolve to exactly one repo and execute that repo's local skill. Never improvise the workflow from memory.

1. **Resolve the repo.** In order of precedence:
   - An explicit repo given as the first argument (`/opsx:explore <repo> ...`) or as a leading path segment.
   - The repo whose code or specs the topic is about (Routing table in root `AGENTS.md`).
   - The repo the conversation is already working in.
   - Otherwise use the Routing table in the root `AGENTS.md`; if the target is still ambiguous, **ask** (one question beats working in the wrong repo). Never guess.

   Only repos with a `<repo>/openspec/` directory **and** a `<repo>/.claude/skills/openspec-explore/SKILL.md` qualify. Discover these from the filesystem on every run; do not hardcode the list. A repo with an `openspec/` directory but no skill is not a valid target: say so and stop.

2. **Enter the repo.** Work from `<repo>/` as the working directory, so `openspec` CLI calls and relative paths resolve against that repo's `openspec/`. Read the repo's `AGENTS.md` (and `CONSTITUTION.md` / `openspec/config.yaml` where present) and check the branch against the Branch Model before proceeding.

3. **Execute the repo-local skill.** Read `<repo>/.claude/skills/openspec-explore/SKILL.md` and follow it exactly as if it had been invoked, passing along the remaining arguments (the topic). The root Skill tool cannot see repo-local skills, so load the file directly.

4. **State which repo and skill ran** at the start of your reply (`Repo: core, skill: openspec-explore`).

## Guardrails

- **One repo per run.** Every OpenSpec change lives in a single repo's `openspec/`; never create or edit artifacts at the workspace root or across repos in one invocation.
- **Repo rules win.** Once inside a repo, its `AGENTS.md` is the source of truth; the root `AGENTS.md` only did the routing.
- **Ask before guessing the repo.** Wrong repo means wasted work.
