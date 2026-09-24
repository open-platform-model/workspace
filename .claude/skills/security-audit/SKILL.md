---
name: security-audit
description: Generic security audit skill — analyzes any codebase (services, CLIs, libraries, web apps, declarative config/schema, IaC) for vulnerabilities, injection risks, access-control gaps, secret leakage, and supply-chain weaknesses. Targets a repo, path, feature, or the full workspace. Produces a severity-ranked report (CRITICAL / WARNING / SUGGESTION). Never modifies code.
user-invocable: true
argument-hint: "[repo | path | feature | all]"
---

Perform a security audit of the codebase. Reports findings ranked by severity — never modifies code.

This is the **architecture-generic fallback** audit. The workspace spans many stacks (pure CUE
schema, Go libraries, a Go CLI, a Go/HTMX web app, a Hugo site, Kubernetes/IaC, encrypted configs),
so this skill reasons from security *principles* and adapts to whatever is in scope rather than
assuming one architecture.

> **Routing note**: If the target repo has its own `<repo>/.claude/skills/security-audit/SKILL.md`,
> that repo-local skill takes precedence — it encodes stack-specific depth this generic skill cannot.
> Use this skill when no repo-local audit exists, or for cross-repo / workspace-wide scope.

## Input

Optionally specify a target after the command:

- **Repo name** (e.g., `cli`, `library`, `core`, `opm-operator`) — audit that repo
- **Path** (e.g., `cli/internal/cmdutil/`, `opm-operator/internal/`) — scope to that subtree/file
- **Feature keyword** (e.g., `authentication`, `path-handling`, `secrets`) — discover related code, then audit
- **`all`** — audit every repo in the workspace
- **Nothing** — ambiguous; ask the user which repo (or `all`) before proceeding

## Scope Detection

- **Repo or path provided** → audit that subtree directly
- **Feature keyword provided** → launch an Explore subagent to find related code, then audit
- **`all`** → workspace-wide audit (per-repo, then cross-repo trust boundaries)
- **Nothing provided** → ask which repo/`all` (don't guess across a multi-stack workspace)

**Detect the stack first.** Before auditing, identify what the in-scope code actually is (HTTP
service, CLI, library, declarative schema, container/IaC, CI). This determines which dimensions
apply and which to skip. Skip any dimension structurally irrelevant to the target.

---

## Audit Dimensions

Nine technology-agnostic dimensions. Each lists its core principle, when it applies, and
representative checks (illustrative, not exhaustive — reason from the principle). Check only the
dimensions relevant to the in-scope stack; record the rest under "Skipped".

### D1 — Input Validation & Injection

*Principle: every value crossing a trust boundary is hostile until validated.*

Applies whenever code consumes untrusted input: HTTP params/bodies, CLI args, config/spec files,
environment variables, file contents, registry/network responses, or user-authored declarative data.

- All external input validated (type, length, range, allowlist) before use
- No path traversal: file paths resolved + confined to an intended root (e.g., `Clean`/`Abs`/`EvalSymlinks`, root-bound checks) before any read/write
- No command/shell injection: user data never interpolated into a shell or `exec` argument list
- No template/SSTI injection: untrusted data not rendered through a text/HTML template without escaping; HTML-context output auto-escaped
- No unsafe deserialization of untrusted payloads
- Declarative-config injection: user-authored CUE/YAML/labels/annotations validated before they influence generated config, selectors, or downstream behavior (no newline/field injection)
- Structured input (selectors, paths, queries) built via safe constructors, not string concatenation

### D2 — Authentication, Authorization & Access Control

*Principle: identity is verified, every privileged action is authorized, and privilege never escalates implicitly.*

Applies to any component that authenticates principals or makes access decisions (web apps, APIs,
controllers acting on behalf of users, multi-tenant logic).

- Authentication is enforced on protected entry points; sessions/tokens are unguessable, scoped, and expire
- Authorization checked at each privileged action (not just at the UI), default-deny
- Role/permission model is least-privilege; no broad/wildcard grants beyond demonstrated need
- No confused-deputy: a low-privilege caller cannot make a high-privilege component act on its behalf beyond intent
- No cross-tenant / cross-namespace / cross-user access via attacker-controlled identifiers
- Privilege boundaries explicit; components don't run with more authority than they use

### D3 — Secrets & Sensitive Data Handling

*Principle: secrets stay out of source, out of output, and minimally exposed at rest.*

Applies anywhere credentials, tokens, keys, or personal/sensitive data are handled.

- No hardcoded credentials, tokens, or keys in source, configs, or fixtures
- Secrets never leak via logs, error messages, events, status fields, stack traces, or generic `%v`/`%+v` object dumps
- Credentials read from files/secret stores, used server-side, and never exposed to clients/browsers or baked into client output
- Secrets held transiently (locals), not persisted in long-lived struct fields or caches
- Encryption-at-rest correct where used (e.g., SOPS/AGE): sensitive fields actually encrypted, key management sound, committed keys clearly demo-only — never a production pattern
- Metadata leakage acknowledged (e.g., names/labels that stay plaintext alongside encrypted data)

### D4 — Cryptography & Integrity

*Principle: use strong, standard primitives correctly, and verify what you trust.*

Applies when code generates randomness, hashes, signs, or fetches/verifies artifacts and dependencies.

- Security-relevant randomness from a CSPRNG (`crypto/rand`), never `math/rand`
- Standard, current algorithms; no homegrown crypto, no broken hashes for security use
- Content/integrity hashing is collision-resistant where it gates security decisions
- Fetched artifacts, modules, and dependencies verified by digest/checksum, not just a mutable tag/name
- No trust in unverified network/registry content before use

### D5 — Network & Transport Security

*Principle: connections are authenticated, encrypted, and bounded.*

Applies to anything exposing or consuming a network surface (HTTP servers, websockets, webhooks,
metrics endpoints, outbound clients).

- TLS for sensitive transport (min TLS 1.2, sane ciphers); certs managed, not ad-hoc self-signed in production
- Every exposed endpoint authenticated/authorized as appropriate; no accidental open admin/metrics/debug surface
- Websocket/upgrade handshakes authenticate before establishing the channel
- CSRF protection on state-changing browser requests; no permissive wildcard CORS
- Request size/header/body limits set to bound abuse
- Health/probe endpoints separated from sensitive endpoints (no auth bypass via a probe path)

### D6 — Availability & Resource Safety

*Principle: untrusted input cannot exhaust resources or corrupt shared state.*

Applies broadly, especially to servers, controllers, and concurrent code.

- Bounds on uploads, request bodies, pagination, recursion, and fan-out — no unbounded consumption
- Resource limits / timeouts on long-running or external operations
- No TOCTOU races on security decisions: prefer act-then-handle-error over check-then-act
- Concurrency-safe: shared mutable state protected; no data races across goroutines/handlers/reconciles
- Cached objects copied before mutation; stale reads not used for security-sensitive decisions
- Failure paths don't deadlock, block deletion, or leave resources pinned

### D7 — Supply Chain & Build

*Principle: what you build and depend on is pinned, verified, and minimal.*

Applies to dependency manifests, build files, CI/CD, and image/artifact publishing.

- Dependencies pinned and integrity-checked (`go.sum`, module version pins, lockfiles)
- No untrusted/unpinned build inputs; build base images and tool versions pinned (not `:latest`)
- CI workflows use least-privilege permissions and pin third-party actions to immutable refs
- Registry/credential handling in build & publish is scoped and not leaked into artifacts or logs
- No secrets baked into image layers or build args; `.dockerignore`/equivalent excludes sensitive files
- Build provenance/reproducibility considered where it matters

### D8 — Container & Orchestration (OPTIONAL)

*Principle: runtime runs with the least privilege it needs.*

**Apply only when containers, Kubernetes manifests, or other IaC are in scope.** If the target repo
has a dedicated repo-local security-audit skill (e.g., the operator), defer the deep version to it and
keep this dimension to a high-level pass.

- Runtime hardening: non-root, read-only root filesystem, no privilege escalation, dropped capabilities, seccomp, resource limits
- Minimal base image (distroless/scratch), no shell/package manager in runtime layer
- Least-privilege platform access: no wildcard RBAC verbs/resources/groups; permissions match actual use; named resources where possible
- Schema/CRD validation present on user-facing fields; immutability and semantic constraints enforced; no user-controlled cross-namespace references (confused deputy)
- Network policies / segmentation restrict ingress & egress
- Manifest image references pinned by digest; security contexts present and restrictive; admission/webhook policies fail-closed where used

### D9 — Architecture & Trust Boundaries

*Principle: security is a property of the whole system, layered, not any single control.*

**Apply for project-wide or cross-subsystem scope** (skip for a single small file).

- **Map trust boundaries**: where privilege level changes (unauthenticated → authenticated → privileged component → managed resources / external systems); where data crosses process, tenant, or repo boundaries
- **Confused-deputy review**: can a limited caller induce a privileged component to act beyond intent? Can attacker-controlled data steer security-relevant behavior (injection, SSRF, escalation)?
- **STRIDE pass** per major data flow crossing a boundary:

  | Threat | Question |
  |--------|----------|
  | **Spoofing** | Can identity (of a request, artifact, or resource) be forged? |
  | **Tampering** | Can data be modified between validation and use, or in transit/at rest? |
  | **Repudiation** | Are privileged actions auditable/attributable? |
  | **Information Disclosure** | Can secrets/sensitive data leak via output, logs, errors, caches? |
  | **Denial of Service** | Can input trigger unbounded consumption or wedge the system? |
  | **Elevation of Privilege** | Can a low-privilege actor reach higher privilege? |

- **Defense in depth**: no single control is the sole protection; least privilege applied across input validation, authz, runtime, and network layers

---

## Technology Adaptation

Adapt the dimensions to the in-scope stack family. Cues, not separate checklists — they point back
into D1–D9.

- **Go services & CLIs** (`cli`, `library`, `opmodel.dev`, controllers) — CSPRNG vs `math/rand` (D4); checked errors on security-sensitive calls; safe path handling and no `exec`/template injection (D1); no secrets in logs/errors (D3); race-free concurrency (D6); HTTP server hardening if it serves (D5). For CLIs, focus on arg/path/config input (D1) and supply chain (D7).
- **Web apps** — auth/session/cookie handling and per-action authz (D2); path traversal on file operations and command exec via terminal/PTY channels (D1); CSRF and websocket auth (D5); credential isolation from the browser (D3); upload/body/dir-size bounds (D6).
- **Declarative config & schema** (`core`, `catalog`, `enhancements`, `modules`, `releases`; CUE/YAML; SOPS/AGE) — constraint/validation strength and injection via user-authored fields/labels (D1); encryption-at-rest correctness and key management (D3); integrity/digest verification of pulled modules (D4); dependency pinning (D7). Most runtime dimensions (D5/D6/D8) usually don't apply.
- **Containers & IaC** (`opm-operator`, `opm-suite-installer`, Dockerfiles, manifests) — D8 in full, plus image/supply-chain (D7) and secret/SOPS handling (D3).
- **CI/CD** (`.github/workflows`) — least-privilege permissions, pinned actions, no secret leakage, no untrusted PR-triggered execution (D7).

---

## Execution Steps

### Workspace-wide or full-repo audit

1. **Detect the stack & map the attack surface.** Launch an Explore subagent to identify, for the
   in-scope code: languages/frameworks, external entry points (HTTP, CLI, file, network, registry),
   trust boundaries, secret/credential handling, dependency & build files, and any
   container/IaC/manifests. Use this to select applicable dimensions.

2. **Audit each applicable dimension.** Launch Explore subagents (parallelize independent
   dimensions) to check the in-scope code. Each subagent returns findings with: **file path**,
   **line number(s)**, **what the issue is**, **why it matters**, and **severity**.

3. **Apply technology adaptation** for the detected stack family.

4. **Deduplicate, rank, and generate the report.**

### Targeted audit (path or feature)

1. **Identify scope.** A path is used directly; a feature keyword is resolved to related code via an
   Explore subagent.

2. **Apply only relevant dimensions** for that stack and surface. Apply D9 (Architecture) only if the
   target spans a trust boundary.

3. **Generate the report.**

---

## Severity Classification

| Severity | Definition | Examples |
|----------|-----------|----------|
| **CRITICAL** | Exploitable vulnerability, privilege escalation, data exfiltration, or auth bypass. Must be fixed before deployment. | Path traversal allowing arbitrary file read/write, command injection from user input, missing auth on a privileged endpoint, hardcoded production credentials, cross-tenant data access, unverified artifact execution |
| **WARNING** | Security weakness with material impact, or a best-practice violation that meaningfully increases attack surface. Address this cycle. | Missing input validation, broader-than-needed permissions, secrets in log output, missing CSRF protection, unpinned dependencies/images, container running as root, missing request size limits |
| **SUGGESTION** | Defense-in-depth or hardening improvement; theoretical risk with low current exploitability. Address when convenient. | Add semantic validation rules, tighten an already-scoped permission, add seccomp/readonly-rootfs, disable an unused protocol, minor logging-hygiene improvement |

### Classification Heuristics

- **Exploitability**: Can a low-privilege/untrusted actor trigger it, or does it require existing high privilege?
- **Impact**: Worst-case outcome (system compromise, data leak, DoS, information disclosure)?
- **Scope**: How many users, tenants, or resources are affected?
- **False positives**: When uncertain, prefer SUGGESTION over WARNING, WARNING over CRITICAL.
- **Confidence**: Only report findings with ≥ 80% confidence. If uncertain, state the uncertainty and suggest investigation rather than asserting a vulnerability.

---

## Report Format

```markdown
## Security Audit Report

### Scope
- **Target**: Workspace (`all`) | Repo `<name>` | `<path>` | Feature: `<name>`
- **Stack detected**: (e.g., Go CLI · CUE schema · Go/HTMX web app)
- **Date**: YYYY-MM-DD

### Summary
| Dimension                                | Status              |
|------------------------------------------|---------------------|
| D1 Input Validation & Injection          | N issues / Clean    |
| D2 AuthN/AuthZ & Access Control          | N issues / Skipped  |
| D3 Secrets & Sensitive Data              | N issues / Clean    |
| D4 Cryptography & Integrity              | N issues / Skipped  |
| D5 Network & Transport                   | N issues / Skipped  |
| D6 Availability & Resource Safety        | N issues / Clean    |
| D7 Supply Chain & Build                  | N issues / Clean    |
| D8 Container & Orchestration             | N issues / Skipped  |
| D9 Architecture & Trust Boundaries       | N issues / Skipped  |

(Dimensions not relevant to the in-scope stack show "Skipped".)

**Totals**: X CRITICAL · Y WARNING · Z SUGGESTION

### CRITICAL (Must fix)

1. **[Title]** — `file/path:line`
   **Dimension**: (e.g., D1 Input Validation & Injection)
   **Description**: What the issue is and how it could be exploited
   **Evidence**: Code snippet or pattern observed
   **Recommendation**: Specific fix with file/line target

### WARNING (Should fix)

1. **[Title]** — `file/path:line`
   **Dimension**: ...
   **Description**: ...
   **Evidence**: ...
   **Recommendation**: ...

### SUGGESTION (Nice to fix)

1. **[Title]** — `file/path:line`
   **Dimension**: ...
   **Description**: ...
   **Recommendation**: ...

### Positive Observations
- (Security practices done well — always include at least one)

### Skipped / Out of Scope
- (Dimensions or checks skipped and why — e.g., "D5/D8 skipped: pure declarative schema, no runtime surface")

### Final Assessment
- If CRITICAL issues: "X critical issue(s) found. Address before deployment."
- If only warnings: "No critical issues. Y warning(s) to consider."
- If all clear: "All checks passed. No security issues identified in scope."
```

---

## Guardrails

- **NEVER make code changes** — this skill is analysis and reporting only
- **Detect the stack before auditing** — don't apply dimensions that don't fit the architecture in scope
- **Delegate deep analysis to Explore subagents** — protect the main context window from the volume of file reads and greps
- **Prefer the repo-local skill** — if the target repo has its own `security-audit` skill, that takes precedence for stack-specific depth
- **≥ 80% confidence threshold** — if uncertain, state it and suggest investigation rather than asserting a vulnerability
- **Always include Positive Observations** — an audit that only reports negatives erodes trust and misses confirming what works
- **Always include Skipped / Out of Scope** — the requestor needs to know what was NOT checked
- **Include code evidence** — every CRITICAL and WARNING cites a `file:line` and shows the relevant pattern
- **Be specific in recommendations** — "fix the validation" is not actionable; name the file/line and the concrete change
- **Do not overstate severity** — a theoretical risk with no current exploitability path is a SUGGESTION, not a CRITICAL. Crying wolf undermines the report
- **Respect the target scope** — a targeted audit stays in scope; note adjacent concerns under "Skipped / Out of Scope" rather than expanding unbounded

## Graceful Degradation

- **No network/HTTP surface** → skip D5 (Network & Transport); note in Skipped
- **No auth or multi-tenant logic** → skip D2; note in Skipped
- **No containers/IaC/manifests** → skip D8; note in Skipped
- **Pure declarative schema/config** (e.g., CUE) → focus on D1 (injection via user-authored fields), D3 (secret/encryption handling), D4 (integrity), D7 (supply chain); skip runtime dimensions D5/D6/D8
- **Single library file or small targeted scope** → skip D8/D9 (Container, Architecture); note in Skipped
- **No build/dependency files in scope** → skip D7; note in Skipped
- Always record which dimensions were skipped and why
