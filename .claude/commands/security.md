---
name: "Security Audit"
description: Route a security audit to the target's local `security-audit` skill, falling back to the nearest available one. Produces a severity-ranked report (CRITICAL / WARNING / SUGGESTION) — never modifies code.
category: Security
tags: [security, audit, analysis, router]
---

Run a security audit by **routing** the target to the closest `security-audit` skill and executing it. This command is the router: figure out what the user wants audited, find the most specific `security-audit` skill that applies, and run it. It never modifies code — every run produces a severity-ranked report (CRITICAL / WARNING / SUGGESTION).

**Input**: Optionally specify a target after `/security`:

- A subproject or directory name → audit that area
- A path → audit that subtree (the subproject is the leading path segment)
- A feature or concept keyword → ambiguous; ask which area to audit first
- `all` → audit every subproject in the workspace
- Nothing → ambiguous; ask which area, or `all`

## Routing

1. **Understand the target.** Use the argument and your knowledge of the workspace layout to resolve what should be audited — a single subproject, a path within one, the whole workspace (`all`), or (when ambiguous) ask the user before proceeding. Do not guess the area from a bare feature keyword.

2. **Find the skill.** For each resolved target, locate the most specific `security-audit` skill that applies (`.claude/skills/security-audit/SKILL.md`): prefer one local to the target's own subproject; if it has none, fall back to the nearest available one up the tree (workspace root). Discover these from the filesystem each run — never hardcode which areas have their own.

3. **Execute it.** Load and run the chosen skill, passing along any in-scope path or feature. When the fallback skill was used because the target has no dedicated one, say so in the report.

4. **Report.** Emit the severity-ranked report defined by the executed skill. For multi-target or `all` runs, present one section per target, each labeled with the area audited and whether it used a local skill or a fallback.

## Guardrails

- **Never modify code** — this command and the skills it routes to are analysis and reporting only.
- **Ask before guessing the area** — a feature keyword or empty argument is ambiguous; one question beats auditing the wrong place.
- **Always state which skill ran** — local vs. fallback — so the reader knows whether the checks were tailored to the target or generalized.
