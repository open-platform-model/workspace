# Releasing and the Release Cascade

When one Open Platform Model (OPM) repo releases, every repo that depends on it has to move its
version pins. Until now a person did that by hand, one repo at a time. The release cascade does it
with bots: each release wakes its downstream repos, and each of those opens one pull request (PR)
that moves the pins. A human still reviews and merges every PR.

This file is the design and the policy. Each repo's OpenSpec changes implement it and cite it as
"workspace RELEASING.md, section <name>". The decisions here were made by the owner on
2026-10-01 and 2026-10-02. No enhancement backs them.

What the cascade fixes is lag: pins forgotten for days, an embedded operator one release behind,
76 hand-made bump commits in two months. What it does not fix is a break that no pin change
exposes. For that, the cli needs a cluster-backed end-to-end (e2e) job in CI (see "Gates", G4).

Words used below:

- **Pin**: a line that names an exact version of something another OPM repo produces, such as
  `github.com/open-platform-model/library v1.0.0-beta.1` in `go.mod` or `v: "v2.0.0-beta.1"` in a
  `cue.mod/module.cue`.
- **Upstream** and **downstream**: core is upstream of library; the cli is downstream of library.
- **Release PR**: the PR release-please keeps open on `main`. Merging it tags a release.
- **Cascade PR**: the bot PR on the branch `deps/cascade` that moves a repo's pins.
- **opm CLI**: the `opm` binary from the `cli` repo. **opm catalog**: `opmodel.dev/catalogs/opm@v4`
  from `catalog_opm`. They are different things with the same short name.
- **GHCR**: the GitHub Container Registry (`ghcr.io/open-platform-model`), where the CUE modules
  and catalogs are published as OCI artifacts.
- **Glue**: the library code that adapts the kernel to one core schema version (the loader around
  `DefaultSchemaModule` and what reads core's definitions). A core bump can break it without any
  pin conflict.
- **Identity-advance commit**: the `chore: advance <catalog> identity.Version to <version>` commit
  that catalog_opm's release workflow pushes onto its own release PR, so each catalog's
  `identity/identity.cue` declares the version it is released as.
- **Sandbox repos**: two throwaway repos the owner creates in Phase 0 to rehearse a full
  upstream-to-downstream cascade cycle before any real repo joins.

## Release order

The repos release in tiers. A tier is a group of repos that may release at the same time. A repo
releases only after every repo it ships against has released.

| Tier | Repos | Ships against |
| --- | --- | --- |
| 0 | `core` | nothing OPM-owned |
| 1 | `catalog_opm` (opm and k8s catalogs) and `library`, in parallel | core |
| 2 | `opm-operator` | library |
| 3 | `cli` | library, opm-operator (embedded `install.yaml`), the opm catalog and core (templates) |
| leaves | `modules`, `opm-suite-installer`, `opm-modules` | stay manual |

- catalog_opm and library do not depend on each other for anything they ship. library uses the opm
  catalog only in tests.
- The cascade stops at the cli. The three leaves keep their manual bumps for now. Their pins move
  with `task deps:update` and `task deps:pins:opm-cli` as before. `opm-suite-installer` is in no
  root pin task yet, so its pins move by hand.
- Two edges run backwards: the opm CLI is installed by catalog_opm's and opm-operator's CI and
  release jobs. These are release-tool pins (see "Pin classes"). They never cut a release, so the
  loop always ends.
- What the order guarantees: nothing consumes a version that is not yet published, no release
  ships a dev pin (G1), a stale shipped pin is flagged (G2), and a repo that pins both a catalog and
  core keeps core at the version that catalog was built on.
- What it does not guarantee: waiting for an upstream release that is still in flight. G3 warns
  about that. A human decides the merge order.

## Pin classes

What a pin is for decides its commit type when it moves.

| Class | Meaning | Commit type | Releases |
| --- | --- | --- | --- |
| shipped | Users receive it: a Go module, an embedded file, a published catalog, a cli template | `fix(deps)` | yes |
| test | Only tests, samples, examples or the dev harness use it | `test(fixtures)` | no |
| frozen | A test pins an old version on purpose; listed in `.cascade-frozen` | never moved | no |
| release-tool | A tool a repo's CI or release job installs; a bad one can block a publish | `ci(deps)` | no |

Where the pins live today:

| Repo | Class | Where | Upstream |
| --- | --- | --- | --- |
| `catalog_opm` | shipped | `opm/cue.mod/module.cue` and `k8s/cue.mod/module.cue`; both core pins stay equal | core |
| `catalog_opm` | release-tool | `.opm-cli-version` (today `OPM_CLI_VERSION` in three workflows) | opm CLI |
| `library` | shipped | `DefaultSchemaModule` in `opm/schema/loader.go`; `DefaultCoreVersion` in `opm/internal/registrytest/registrytest.go` derives from it once `derive-fixture-versions` lands (a hand-kept mirror until then) | core |
| `library` | test | the `cue.mod` files under `modules/`, `testdata/modules/`, `testdata/parity/`, `testdata/cue.mod`, `testdata/render/**`, and the version literals in kernel tests | core, opm catalog |
| `library` | frozen | see library's `.cascade-frozen` (created by `derive-fixture-versions`) | none |
| `opm-operator` | shipped | `go.mod` (`github.com/open-platform-model/library`) | library |
| `opm-operator` | test | `config/samples/`, `test/fixtures/` (including `CatalogVersion()` in `test/fixtures/catalog.go`) | core, catalogs |
| `opm-operator` | release-tool | `.opm-cli-version` (today `go install .../cli/cmd/opm@` in four workflows) | opm CLI |
| `cli` | shipped | `go.mod` (library) | library |
| `cli` | shipped | `PinnedOperatorVersion` in `internal/operator/manifest.go` plus `internal/operator/dist/install.yaml`, always moved together | opm-operator |
| `cli` | shipped | `templates/{minimal,standard,advanced}/cue.mod/module.cue`, plus each template's own version | core, opm catalog |
| `cli` | test | `hack/platform/cue.mod`, `hack/kind-platform.yaml`, `examples/cue.mod`, `tests/fixtures/` (including `tests/fixtures/valid/{simple-module,module-with-debug-values}/cue.mod`), `tests/e2e/testdata/operator-owned/`, and the `cue.mod` files under `internal/instinit/testdata/initvalues/`, `internal/workflow/render/testdata/skip-unprovided/`, `tests/e2e/testdata/duplicate-identities/` and `tests/integration/module-apply/testdata/` | core, catalogs |
| `cli` | frozen | in `tests/e2e/instance_build_test.go`, the older-core platform, `collisionCorePin` and `olderCatalogPin` (`opmodel.dev/catalogs/opm@v4`); the old core pins in `internal/cmd/platform/check_test.go`; the `TestRender_Golden` core literal in `internal/instinit/render_test.go`; all listed in cli's `.cascade-frozen` (created by `bump-stale-testdata-pins`) | none |

core pins nothing OPM-owned and has no receiver.

Third-party pins (`CUE_VERSION`, the kind node image, Flux, `cue.dev/x/k8s.io@v0`) are out of
scope. The cascade never moves them. It warns when an upstream's `language.version` is newer than
the local `CUE_VERSION`.

The type follows what ships. The full type rule lives in the workspace commit skill,
`.claude/skills/commit/SKILL.md`:

- `feat`, `fix`, `perf` and `revert` release in every repo. `deps` releases in library,
  opm-operator and cli; core and catalog_opm do not list it, so release-please drops a `deps:`
  commit there.
- `test`, `ci`, `build`, `chore` and `style` never release.
- `refactor` releases in library, opm-operator and cli, so early library rewrites reach their
  consumers.
- `docs` stops releasing in library, opm-operator and cli once each repo's
  `prepare-release-cascade` change hides it. Until then a docs-only merge there still cuts a
  release and starts a cascade.
- Hiding `docs` delays docs on opmodel.dev unless the site builds those repos' docs from the
  release-branch head, as it already does for core and catalog_opm. Today it builds library and
  opm-operator docs at what the newest cli tag pins, and cli docs at that tag. The opmodel.dev
  change `build-docs-from-branch-head` moves library, opm-operator and cli to the branch head (owner
  decision 2026-10-02), and the docs-hiding section of each `prepare-release-cascade` merges only
  after it. Until then a docs-only fix in those repos reaches opmodel.dev only with the next
  release.

## Bump rule

A downstream bump is typed by what changes for the downstream's own users, not by what changed
upstream.

- **`fix(deps)` is the default** for any shipped pin. It cuts a patch release (on a beta line, the
  next `beta.N`).
- **A human retitles the PR** to `feat(deps)` when the downstream's users gain something from the
  new upstream, or adds `!` (`fix(deps)!:`) when the bump breaks them.
- **The bot never lowers a type and never drops a `!`.** Once a human retitles a cascade PR, the
  bot stops rewriting the title.
- **The label `deps-cascade:breaking`** is added when an upstream changelog in the bump has a
  "BREAKING CHANGES" section. It prompts the retitle; it does not decide it.
- **A new major is never crossed by the bot.** Moving to `opmodel.dev/core@v3` or
  `opmodel.dev/catalogs/opm@v5` is a hand-made crossing: an ordinary PR that changes the import
  paths and fixes what breaks. The bot only reports "new major available".
- **Beta lines just advance `beta.N`.** While a repo releases `X.0.0-beta.N` (core, the k8s
  catalog, library, opm-operator, cli), every releasing type, `!` included, moves it to the next
  `beta.N`. The type still decides whether a release happens and what the changelog says.
- **The opm catalog is a stable 4.x line.** There `feat(deps)` cuts a minor release, and `!` would
  make release-please propose 5.0.0 while the module path stays `opmodel.dev/catalogs/opm@v4`.
  Never add `!` to catalog_opm's cascade PR, even under `deps-cascade:breaking`. A breaking
  adoption there is a hand-made major crossing to `opm@v5`.
- **Test and release-tool pins never release.** A cascade PR that moves only test pins is
  `test(fixtures)`. One that moves only the opm CLI pin is `ci(deps)`.
- **A cascade PR may mix classes.** The shipped bump and the test, fixture or release-tool edits in
  the same PR squash together as one `fix(deps)` commit. This is the one exception to the commit skill's "never mix a
  shipped bump and a fixture bump" rule. It holds only in a `deps-cascade` PR.

## The cascade

### Notify after publish

Each upstream repo gets a final `notify-downstream` job. It runs only after the artifact is really
public, never on the release event itself.

| Upstream | Notify runs after | Dispatches to |
| --- | --- | --- |
| `core` | `publish-cue` | catalog_opm, library |
| `catalog_opm` | the publish step of `publish-cue` (its `join-release-cascade` moves verification to its own job) | library, opm-operator, cli |
| `library` | `release-please` (the job gains a `release` step id and outputs) | opm-operator, cli |
| `opm-operator` | `publish-release` (draft published, assets attached) | cli |
| `cli` | `goreleaser` and `publish-templates`, also on the manual recovery path | catalog_opm, opm-operator (release-tool only) |

- core does not dispatch to opm-operator or the cli. Their core pins follow the opm catalog, so a
  core-only dispatch would change nothing there.
- catalog_opm sends one dispatch per run, listing every tag it published.
- The notify job runs in the `cascade` Environment, which holds the App key. The Environment is
  declared inside the reusable notify workflow, because a caller job that uses `uses:` cannot set
  `environment`. That is why core needs the Environment even though it has no receiver.

### repository_dispatch

A notify job calls `POST /repos/open-platform-model/<repo>/dispatches` with the event type
`upstream-released` and the payload `{"source": "<repo>", "tags": ["<tag>", ...]}`.

- It authenticates with a token from the `opm-cascade` App (see "Owner settings"). The built-in
  `GITHUB_TOKEN` cannot reach another repo.
- The receiver uses the payload only for the log and the PR body. It never trusts the version in
  it. It resolves "newest published" itself.
- The shared notify and receive workflows live in the org `.github` repo and are called at `@main`.

### The receiver

Each repo has `.github/workflows/deps-cascade.yml`. It runs on three triggers:

- `repository_dispatch` with type `upstream-released`
- a daily schedule, the sweep that catches a lost dispatch, so a miss costs at most one day
- `workflow_dispatch`, with a `dry_run` input that writes the diff to the job summary and pushes
  nothing

The receiver runs the repo's own `task deps:cascade`. That task exits 0 when it changed files, 3
when there was nothing to do, and any other code on error. It never swallows a failure. It uses one
shared resolver from the `.github` repo (the `add-cascade-resolver` change), with these rules:

- **Newest** is one exact version, sorted by semver, within the major the repo consumes. For the
  operator and the opm CLI it is the newest published, non-draft release.
- **Published** means GHCR (CUE modules) or `proxy.golang.org` (Go modules) serves it. A git tag
  alone is not enough.
- **Pins never move backwards.** If the newest tag is not published yet, the pin stays.
- **Consistent set.** Where a repo pins a catalog and core together, core moves to the version that
  catalog pins. library differs: core in its test modules equals `DefaultSchemaModule`, which moves
  first under `need-human-review` (see library `derive-fixture-versions`).
- **Frozen pins** in `.cascade-frozen` are never touched. **Held pins** in `.cascade-hold` stop at
  their `max`.
- **Version advances happen once per PR.** A fixture or template version is set to `main`'s
  declared version plus one, never bumped again on each run.

### One rolling PR per repo

Each repo has at most one open cascade PR, on the branch `deps/cascade`. It absorbs every upstream
release until a human merges it.

- **No open PR:** the bot branches from `origin/main`.
- **Open PR with only bot commits:** the bot rebuilds the branch from `origin/main`. No human work
  can be lost.
- **Open PR with a human commit:** the bot runs `git merge origin/main`, never a rebase, then adds
  its own commit on top.
  - A conflict only in derived files (`go.mod`, `go.sum`, `cue.mod/module.cue`,
    `internal/operator/dist/install.yaml`, `manifest.go`) takes `main`'s side. The next step
    regenerates them.
  - Any other conflict stops the run and adds `deps-cascade:conflict`.
- **No diff against `main`:** the bot closes the PR.

### Additive commits

Bot commits are added, never rewritten, once a human has pushed to the branch. A human can push
fix commits to `deps/cascade` and the next bot run keeps them. The squash message is `BLANK` (see
"Owner settings"), so only the PR title reaches `main`: branch commit messages and the PR body
never do.

### Title from diff class

The bot computes the PR title from the whole diff against `main`, human commits included:

1. `fix(deps): ...` when any shipped-class path, or any path outside the test and release-tool
   classes, changed
1. `test(fixtures): ...` when test-class paths changed and no shipped path did
1. `ci(deps): ...` when only release-tool pins changed

The title names the moved pins, for example `fix(deps): bump core to v2.0.0-beta.2 and opm catalog
to 4.4.5`. With four or more moved pins it becomes `fix(deps): bump 4 upstream pins`. The body is
regenerated on each run. It holds a table of moved pins, the triggering releases, warnings, a
`## Notes` section the bot never edits, and a hidden title marker. The bot lints its own commit
messages, the title and the body for a bare `@word`, which mention-guard fails and GitHub turns
into a ping. Human commits on `deps/cascade` are not linted by the bot; mention-guard still checks
them. Under the `BLANK` squash message only the title reaches `main`, so a `BREAKING CHANGE:` or
`Release-As:` line in a quoted upstream changelog, or in any commit body, does nothing.

### Concurrency

Each receiver uses the concurrency group `deps-cascade` without cancelling: one run active, one
pending. A burst of releases collapses into the newest pending run. That is safe because the task
resolves "newest" itself.

### Two-job split

The receive workflow runs as two jobs, so the job that runs repository code never holds the App
key.

- **`compute`** has no secrets and read-only contents. It validates the payload, picks the base,
  runs `task deps:cascade`, builds the title and body, lints them, and uploads the result as a git
  bundle.
- **`publish`** runs in the `cascade` Environment, which only `main` can use. It mints the App token
  right before use, pushes the bundle, creates or updates the PR, and sets the G2 and G3 commit
  statuses on any open release PR. If a human pushed in between, `publish` fails and the pending
  run, the next dispatch or the daily sweep retries; `publish` never reruns repository code.

### Labels

Every cascade label has one colour and one description in every repo:

| Label | Colour | Description | Set by |
| --- | --- | --- | --- |
| `deps-cascade` | `0366d6` | Rolling upstream-pin PR opened by the release cascade | bot |
| `deps-cascade:conflict` | `b60205` | The bot could not merge main into this cascade PR; a human resolves it | bot |
| `deps-cascade:hold` | `fbca04` | A human is working on this cascade PR; the bot does not push | human |
| `deps-cascade:breaking` | `d93f0b` | An upstream changelog in this PR announces a breaking change | bot |
| `need-human-review` | `e99695` | Glue edits a human must review before merging | bot, always on a library core bump (the bump moved `DefaultSchemaModule`) |
| `e2e-verified` | `0e8a16` | A human ran task test:e2e against the embedded operator (G4) | human |

`deps-cascade:hold` is about the PR, not about pins: it means a human is pushing to `deps/cascade`.
Holding a pin back is `.cascade-hold` (see "Cascade files").

In the cli, `.github/labels.yml` declares every label above, so the cascade receiver must not create
labels there. The cli label sync deletes undeclared labels, so `labels.yml` also declares the five
labels other bots set, with their live values:

| Label | Colour | Description | Set by |
| --- | --- | --- | --- |
| `autorelease: pending` | `ededed` | none | release-please |
| `autorelease: tagged` | `ededed` | none | release-please |
| `dependencies` | `0366d6` | Pull requests that update a dependency file | Dependabot |
| `go` | `16e2e2` | Pull requests that update go code | Dependabot |
| `github_actions` | `000000` | Pull requests that update GitHub Actions code | Dependabot |

### What each repo's task moves

| Repo | Shipped | Test and release-tool |
| --- | --- | --- |
| `catalog_opm` | core in `opm/` and `k8s/`, both to the same version | `.opm-cli-version` |
| `library` | `DefaultSchemaModule` only, labelled `need-human-review`; `DefaultCoreVersion` and the other test literals derive from it after `derive-fixture-versions` | test `cue.mod` files and the parity catalog |
| `opm-operator` | `go get` library and `go mod tidy` | samples, `test/fixtures/catalog.go`, fixtures, `.opm-cli-version` |
| `cli` | `go get` library; `task operator:sync` to the newest published operator; templates and their versions | `hack/platform`, `hack/kind-platform.yaml`, `examples`, the podinfo fixture, and the six testdata `cue.mod` files that `bump-stale-testdata-pins` brings current (`tests/fixtures/valid/simple-module`, `tests/fixtures/valid/module-with-debug-values`, `internal/instinit/testdata/initvalues`, `internal/workflow/render/testdata/skip-unprovided`, `tests/e2e/testdata/duplicate-identities`, `tests/integration/module-apply/testdata`) |

No cascade PR auto-merges. Release PRs are always merged by a human.

## Gates

| Gate | Where | Rule | Status |
| --- | --- | --- | --- |
| G1 release-pin gate | Release PRs in catalog_opm, library, opm-operator, cli | Fails on a Go `replace`, a pseudo-version or untagged OPM Go pin, a `-0.dev.` pin in a shipped `cue.mod` (library: any tracked `cue.mod`; opm-operator: its published fixture `cue.mod`s), a tracked `cue.mod/local-module.cue`, or (cli) `PinnedOperatorVersion` not matching the image tag in `install.yaml` | Required: a step in the required job, binding once the ruleset requires that job |
| G2 `cascade/freshness` | Commit status on the release PR head | Fails when a shipped pin is behind the newest published upstream, unless `.cascade-hold` holds it | Warning; required once `.cascade-hold` exists and two weeks live show no false alarms |
| G3 `cascade/settled` | Commit status on the release PR head | Warns while an upstream has an open `fix(deps)` cascade PR, or a pending release PR that contains a merged `fix(deps)` cascade | Warning; required after two weeks without false alarms |
| G4 `e2e-verified` label | cli release PRs (check `G4 operator-embed evidence`) | When `PinnedOperatorVersion` changed since the last cli tag, the PR needs the label | Interim; retires only when all three retirement conditions below hold |

- **G1 detection.** G1 runs when `${{ github.head_ref || github.ref_name }}` starts with
  `release-please--`. core and catalog_opm dispatch release-PR CI with `workflow_dispatch`, where
  `head_ref` is empty, so the `ref_name` fallback is needed.
- **G1 placement.** G1 runs as a step inside an existing required job, never as a new job. A skipped
  job reports as passing, a failing step does not.
- **G2 and G3 freshness.** Every receiver run refreshes both statuses on any open release PR, so
  an upstream that publishes later is picked up by the next run. When the release PR head moves
  (a merged cascade PR, catalog_opm's identity-advance commit), the statuses are missing until the
  next dispatch or the daily sweep; run `deps-cascade.yml` with `workflow_dispatch` to refresh them
  at once.
- **G4 replacement.** The cli change `add-embedded-operator-e2e-job` adds a CI job: a kind cluster,
  the embedded operator, a seeded Platform and the e2e suite. It runs on PRs that touch
  `internal/operator/` or `templates/`, on cascade PRs, and on release PRs. Its check is
  `E2E (kind, embedded operator)`.
- **G4 retirement.** G4 retires only when all three hold (owner decision 2026-10-02):
  `add-embedded-operator-e2e-job` has merged, its check has passed on at least one cli release PR,
  and that check is required in the cli ruleset. Retiring G4 is then its own cli change,
  `retire-g4-operator-embed-evidence`. Until all three hold, G4 stays.
- **Enforcement needs rulesets.** library, opm-operator and cli have no required CI checks besides
  the org mention-guard today. Until the rulesets in "Owner settings" exist, every gate there is
  advisory.
- **Rejected: "an open cascade PR blocks the release".** It deadlocks with the backwards opm CLI
  edge.

## Cascade files

Three repo-root files steer the cascade. Each is optional for the cascade: a repo without
`.cascade-frozen` or `.cascade-hold` behaves as if it were empty, and a repo without
`.opm-cli-version` has no opm CLI pin to move. A repo whose CI reads `.opm-cli-version` must keep
it.

### .opm-cli-version

One line: the opm CLI tag that CI and the release job install.

```text
v1.0.0-beta.4
```

How CI reads it is up to each repo. One example is
`echo "OPM_CLI_VERSION=$(cat .opm-cli-version)" >> "$GITHUB_ENV"`; a repo may instead read and
check the value inline in its install step, as opm-operator does. Keeping the pin out of
`.github/workflows/` means the cascade App never edits a workflow file. The workspace
`task deps:pins:opm-cli` writes this file in every repo that has one.

### .cascade-frozen

Pins that a test keeps old on purpose. The bot never moves them, and G2 ignores them.

```yaml
frozen:
  - path: tests/e2e/instance_build_test.go   # repo-relative file or directory
    pins: ["opmodel.dev/core@v2"]            # module paths frozen at that location
    reason: "one sentence: why this pin must stay old"
```

Every entry needs a reason. An old pin without an entry is stale: `deps:cascade` moves it where the
task covers that path, otherwise a human bumps it.

### .cascade-hold

Shipped pins that must not move past a version for now, usually because the newer upstream breaks
this repo.

```yaml
holds:
  - pin: "github.com/open-platform-model/library"
    max: "v1.0.0-beta.1"
    reason: "one sentence"
    expires: "2026-11-01"
```

The bot stops a held pin at `max`. G2 accepts it while the hold is in date. After `expires` the hold
lapses: the bot moves the pin again and G2 stops accepting it. A hold is a decision with a
deadline, not a mute button.

## Runbook

### Handling a cascade PR

1. Read the body: the moved pins, the warnings, and the labels `need-human-review` and
   `deps-cascade:breaking`.
1. Decide the type. Leave `fix(deps)` unless the downstream's users gain a feature (`feat(deps)`) or
   break (`!`). See "Bump rule".
1. If CI is red, add `deps-cascade:hold`, push fix commits to `deps/cascade`, then remove the label.
   Subjects should still be Conventional; they never reach `main`.
1. On `deps-cascade:conflict`, run `git merge origin/main` locally, resolve, push, and remove the
   label.
1. If the upstream is broken for this repo, land an entry in `.cascade-hold` on `main` by PR, with
   a reason and an expiry, then close the cascade PR. Closing alone lasts only until the next
   receiver run (at most a day, the daily sweep); `deps-cascade:hold` on the PR or a
   `.cascade-hold` entry is what stops it.
1. On "new major available", do the crossing as an ordinary hand-made PR.
1. On `need-human-review` (library core bump), check the glue against the new core before merging.
1. Merge with `gh pr merge <N> --squash --match-head-commit <sha>`, where the SHA is the head you
   saw green.

### Merging release PRs

Merge tier by tier: core, then catalog_opm and library, then opm-operator, then the cli. Before
merging a release PR, check that `cascade/freshness` and `cascade/settled` are green, or that you
know why not. If they are missing on the current head, run `deps-cascade.yml` with
`workflow_dispatch` first.

- In catalog_opm, the release PR gains an identity-advance commit; wait for it before merging.
- On the cli release PR, if `PinnedOperatorVersion` changed since the last cli tag, run
  `task test:e2e` on its head and add `e2e-verified` (G4). Remove the label if the operator pin
  moves again before merge. This step ends when `retire-g4-operator-embed-evidence` retires G4
  (see "Gates").

### Dependabot PRs

Under the `BLANK` squash message (see "Owner settings") a Dependabot PR squashes to its title
alone, so its third-party release notes never reach `main`. Check only the title's type before
merging.

### Stop switches

From smallest to largest:

- Add `deps-cascade:hold` to one PR: the bot leaves that PR alone.
- Add a `.cascade-hold` entry: one pin stops moving in one repo.
- Set the repo variable `CASCADE_DRY_RUN=true`: the repo's receiver computes but never pushes.
- Disable `deps-cascade.yml` in a repo: it stops receiving.
- Suspend the `opm-cascade` App installation: everything stops at once.

## Owner settings

These are owner-only GitHub settings. The cascade does not work without them: a one-commit bot PR
would squash under its commit subject, which release-please ignores, so nothing would release.
Check each line with `gh api repos/open-platform-model/<repo>` before relying on it.

### Merge settings (core, catalog_opm, library, opm-operator, cli)

- [ ] `squash_merge_commit_title` is `PR_TITLE`
- [ ] `squash_merge_commit_message` is `BLANK` (owner decision 2026-10-02, reversing `PR_BODY`):
  a squash commit carries only the PR title. A ruleset-required mention-guard ignores the `edited`
  event, so a PR-body guard could not see an edit made after a green run. Under `BLANK`:
  - a breaking change is `!` in the PR title (`fix(deps)!:`); a `BREAKING CHANGE:` footer in the
    body or a commit never reaches `main`
  - a forced version is `release-as` in `release-please-config.json`, set by a normal PR and
    removed by the next PR once that release is cut (it pins every later release while it stays);
    a `Release-As:` footer never reaches `main`
- [ ] Squash merge only: merge commits and rebase merges disabled
- [ ] `delete_branch_on_merge` is `true`
- [ ] `allow_auto_merge` stays `false`

### Rulesets on main (core, catalog_opm, library, opm-operator, cli, .github)

- [ ] Every change lands by PR; no direct pushes for anyone
- [ ] Required checks, per repo:
  - core: `Validate schema` (already required through classic branch protection)
  - catalog_opm: `Validate catalog` (carries G1)
  - library: `Go tests` (carries G1, from its `prepare-release-cascade`)
  - opm-operator: `Lint` (carries G1, from its `prepare-release-cascade`)
  - cli: `Lint` (carries G1), and `G4 operator-embed evidence` until
    `retire-g4-operator-embed-evidence` retires G4; once `add-embedded-operator-e2e-job` has
    merged and its check has been green, also `E2E (kind, embedded operator)`
  - `.github`: the CI check its `add-cascade-resolver` change adds, once that change lands
- [ ] Force pushes and branch deletion blocked
- [ ] The owner has a bypass in pull-request-only mode: they can merge a PR past a red check, never
  push to `main`
- [ ] No bypass for the `opm-cascade` App or any other bot

The OpenSpec archive commit rides the implementing PR in these repos. Nothing is pushed to `main`
afterwards. No workflow in these repos pushes to `main` today either: catalog_opm's release
workflow pushes only to `release-please--*` branches and `.github` only to `tag-ledger`. The
`enhancements` and `workspace` repos are unchanged for now.

### The opm-cascade App

- [ ] A new GitHub App `opm-cascade`, separate from `opm-release-please`
- [ ] Repository permissions: Contents read and write, Pull requests read and write, Issues read and
  write (labels and comments), Commit statuses read and write, Metadata read
- [ ] No Workflows permission and no Actions permission
- [ ] Not a bypass actor in `tags-create-app-only` or any branch ruleset
- [ ] Installed on core, catalog_opm, library, opm-operator, cli and the sandbox repos
- [ ] In each of those repos, an Environment `cascade` whose deployment branches are `main` only,
  holding the secret `CASCADE_APP_PRIVATE_KEY`; the App's client ID as the variable
  `CASCADE_APP_CLIENT_ID`
- [ ] Org two-factor authentication required (recommended)

## Rollout and changes

### Phases

| Phase | Content | Gate to leave it |
| --- | --- | --- |
| 0 Settings | The owner applies "Owner settings" and creates two sandbox repos. Open checks: a one-commit PR squashes under `PR_TITLE` and releases; cross-repo dispatch and App-pushed PR CI work; a bot merge of `main` that changes a workflow file, and the App's "Update branch", are accepted without the Workflows permission; the org Actions policy lets org repos call `.github` reusable workflows; the owner's pull-request-only bypass really merges a PR past a red required check | every checkbox ticked, except a required check whose job a later change adds (it becomes required when that change lands) |
| 1 Prepare | The changes below, in parallel. Drift is caught up by hand first (the cli operator embed is already current at `v1.0.0-beta.4`): opm CLI pins (`ci(deps)`; catalog_opm and opm-operator catch up inside their `prepare-release-cascade`, so do not run `task deps:pins:opm-cli` against them before those merge), and library's four opm catalog `v4.4.2` `cue.mod` files (`modules/opm_platform`, `testdata/modules/web_app`, `testdata/parity`, `testdata/parity/opm_platform`) as `test(fixtures)` | each change merged |
| 2 Tasks | The shared resolver in `.github`, then `task deps:cascade` in each repo | a run on `main` exits 3; a run against an older pin produces the expected diff |
| 3 Wiring | Shared notify and receive workflows in `.github`, then each repo joins with `CASCADE_DRY_RUN=true` | one full two-repo sandbox cycle green; dry runs show the expected diffs |
| 4 Live | Clear the dry-run flag repo by repo; watch every run | two weeks live |
| 5 Harden | Make G2 and G3 required; rewire the workspace `task deps:update` | no false alarms in two weeks |

Phase 1 does not wait for Phase 0: its changes may merge first, and their gates stay advisory
until the rulesets exist. Phase 0 gates Phase 3, because the wiring needs the App, the
Environments and the merge settings.

### Changes

| Phase | Repo | Change | Content | Depends on |
| --- | --- | --- | --- | --- |
| 1 | workspace | branch `docs/release-cascade` (PR, no OpenSpec) | this file, `AGENTS.md`, the commit-skill exception, `task deps:pins:opm-cli` writes `.opm-cli-version` | none |
| 1 | catalog_opm | `prepare-release-cascade` | G1 step; `.opm-cli-version` read by the workflows, and the opm CLI caught up; branch publish skips `deps/**` | workspace doc |
| 1 | library | `prepare-release-cascade` | G1 step; release job outputs; `docs` hidden from the changelog | workspace doc; the `docs` section also opmodel.dev `build-docs-from-branch-head` |
| 1 | library | `derive-fixture-versions` | parity and core test literals derive from one source each, so a bump touches only constants and `cue.mod` files; library's `.cascade-frozen` records the deliberate old pins | none |
| 1 | opm-operator | `prepare-release-cascade` | G1 step; `.opm-cli-version`, and the opm CLI caught up; Dependabot ignores OPM Go modules; `docs` hidden | workspace doc; the `docs` section also opmodel.dev `build-docs-from-branch-head` |
| 1 | cli | `prepare-release-cascade` | G1 step with the embed check; G4 rule; Dependabot ignore; labels in `labels.yml`; `docs` hidden | workspace doc; the `docs` section also opmodel.dev `build-docs-from-branch-head` |
| 1 | opmodel.dev | `build-docs-from-branch-head` | build library, opm-operator and cli docs from the release-branch head, as for core and catalog_opm, so hiding `docs` does not delay docs fixes | none |
| 1 | cli | `bump-stale-testdata-pins` | bump five stale testdata trees (six `cue.mod` files) once as `test(fixtures)`; record the deliberate old pins in `.cascade-frozen` | none |
| 1 | cli | `add-embedded-operator-e2e-job` | cluster-backed e2e CI job, check `E2E (kind, embedded operator)`; the first of the three G4 retirement conditions | none |
| after 1 | cli | `retire-g4-operator-embed-evidence` (working name) | remove the G4 check, its label rule and the runbook step | `add-embedded-operator-e2e-job` merged, its check passed on at least one cli release PR, and that check required (see "Gates") |
| 2 | `.github` | `add-cascade-resolver` (runs `openspec init` there first) | the shared resolver every `deps:cascade` calls; a CI check for `.github` | none |
| 2 | each of the four | `add-deps-cascade-task` | `deps:cascade`, its title and body tasks | `add-cascade-resolver`; its `prepare-release-cascade`; library also `derive-fixture-versions`; cli also `bump-stale-testdata-pins` |
| 3 | `.github` | `add-release-cascade-workflows` | notify and receive workflows, the sandbox cycle | `add-cascade-resolver`, Phase 0 settings |
| 3 | core and the four | `join-release-cascade` | notify job (catalog_opm first splits "Verify the published build" out of `publish-cue`, so a verify finding cannot suppress notify); receiver (not in core, which pins nothing OPM-owned) | `add-release-cascade-workflows`, the repo's `add-deps-cascade-task` and `prepare-release-cascade` |
| 5 | the four | `require-pin-freshness-gate` | make G2 required, then G3 the same way | `join-release-cascade`, `.cascade-hold` in place, two weeks live without false alarms |
| 5 | workspace | rewire `deps:update` (PR) | root tasks call each repo's `deps:cascade` | every `add-deps-cascade-task` |
