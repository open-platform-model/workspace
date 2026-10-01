#!/usr/bin/env bash
# Bump the CUE deps of the PUBLISHED test fixtures and advance each fixture's
# declared version, so the next merge republishes them against current core and
# catalogs. Deliberately outside `task deps:update`: a fixture is an artifact
# on testing.opmodel.dev, and changing what it depends on IS a new version of it.
#
#   cli/tests/fixtures/modules/*            identity/ -> opm module version set
#   opm-operator/test/fixtures/modules/*    identity/ -> opm module version set
#   opm-operator/internal/source/testdata/minimal-module   deps only, no identity
#
# One pass, one PR per repo. Every consumer of a fixture version moves in the
# same run: PR CI in both repos seeds a job-local registry from the tree
# (hack/fixtures.sh seed), so nothing has to wait for GHCR. Consumers:
#   opm-operator  test/fixtures/modulepackages/*/cue.mod (text re-pin, no tidy),
#                 moduleinstance.yaml + config/samples (task examples:pin)
#   cli           tests/e2e/testdata/operator-owned/cue.mod, examples/cue.mod
#                 (text re-pin, no tidy)
# A consumer pins the fixture's new version AND every dep it shares with the
# fixture at the fixture's pin ("follows the fixture"). CUE does not apply MVS
# over a dependency's requirements when the consumer's module.cue already lists
# the dep: `cue mod tidy` keeps a stale core pin and `cue export` silently
# renders the new fixture against the old core. The fixture's deps were just
# moved to latest by bump_deps, so following them never lowers a consumer.
# Go tests read the coordinate from the identity package (tests/fixtures/
# fixtures.go, test/fixtures/fixtures.go) and need no edit.
set -euo pipefail

# Update a module's cue.mod deps in one resolution pass; echo 1 if anything moved.
bump_deps() {
  local dir="$1" deps moved=0 dep old new
  deps=$(sed -n '/^deps: {$/,/^}$/p' "$dir/cue.mod/module.cue" 2>/dev/null | grep -oP '^\s*"\K[^"]+(?=":\s*\{)') || true
  [ -n "$deps" ] || { printf "    (no deps)\n" >&2; echo 0; return; }
  local before; before=$(cat "$dir/cue.mod/module.cue")
  # shellcheck disable=SC2086
  (cd "$dir" && cue mod get $deps > /dev/null 2>&1 && cue mod tidy > /dev/null 2>&1) || true
  for dep in $deps; do
    old=$(grep -FA5 "\"${dep}\"" <<<"$before" | grep -oP 'v:\s*"\K[^"]+' | head -1)
    new=$(grep -FA5 "\"${dep}\"" "$dir/cue.mod/module.cue" | grep -oP 'v:\s*"\K[^"]+' | head -1)
    if [ "$old" != "$new" ]; then
      printf "    %s: \033[1;33m%s\033[0m -> \033[0;32m%s\033[0m\n" "$dep" "$old" "$new" >&2; moved=1
    else
      printf "    %s: \033[2m%s (unchanged)\033[0m\n" "$dep" "$old" >&2
    fi
  done
  echo $moved
}

declare -A newver=() # module path -> declared version, for the consumer re-pins
declare -A fixmod=() # module path -> the fixture's cue.mod/module.cue
for dir in cli/tests/fixtures/modules/*/ opm-operator/test/fixtures/modules/*/ opm-operator/internal/source/testdata/minimal-module/; do
  dir="${dir%/}"; [ -d "$dir/cue.mod" ] || continue
  printf "==> Fixture \033[1;36m%s\033[0m\n" "$dir"
  moved=$(bump_deps "$dir")
  [ -d "$dir/identity" ] || continue
  if [ "$moved" = 1 ]; then
    cur=$(cd "$dir" && cue eval ./identity --out text -e Version)
    next=$(awk -F. -v OFS=. '{$NF=$NF+1; print}' <<<"$cur")
    (cd "$dir" && opm module version set "$next" . > /dev/null)
    path=$(cd "$dir" && cue eval ./identity --out text -e ModulePath)
    newver["$path"]="$next"
    fixmod["$path"]="$dir/cue.mod/module.cue"
    printf "    version: \033[1;33m%s\033[0m -> \033[0;32m%s\033[0m (%s)\n" "$cur" "$next" "$path"
  fi
done

if [ "${#newver[@]}" -eq 0 ]; then
  printf "No fixture moved; nothing to re-pin.\n"
  exit 0
fi

# pin_of <file> <dep>: the v: a module.cue pins <dep> at (empty when absent).
pin_of() { grep -FA5 "\"$2\"" "$1" | grep -oP 'v:\s*"\K[^"]+' | head -1 || true; }

# set_pin <file> <dep> <version>: rewrite the v: line under <dep> (text only).
set_pin() {
  awk -v p="\"$2\"" -v v="$3" 'index($0,p) {f=1} f && /v: "/ {sub(/"[^"]+"/, "\"" v "\""); f=0} {print}' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# follow_fixtures <file>: for every moved fixture <file> pins, move that pin to
# the fixture's new version and every dep <file> shares with the fixture to the
# fixture's pin. Text only: the new fixture version is not on any registry yet,
# so `cue mod get` cannot resolve it here. PR CI checks the result with CUE's
# own resolver against the seeded registry (`hack/fixtures.sh consumers`, the
# subcommand the fixture-consumer-guard changes add to cli and opm-operator).
follow_fixtures() {
  local f="$1" path old dep mv_ cv
  [ -f "$f" ] || return 0
  for path in "${!newver[@]}"; do
    grep -q "\"$path\"" "$f" || continue
    old=$(pin_of "$f" "$path")
    set_pin "$f" "$path" "v${newver[$path]}"
    printf "    %s: \033[1;33m%s\033[0m -> \033[0;32mv%s\033[0m\n" "$path" "$old" "${newver[$path]}"
    while read -r dep; do
      cv=$(pin_of "$f" "$dep")
      if [ -z "$cv" ]; then
        printf "    \033[1;31m%s: pinned by the fixture, missing here; add it with cue mod get once the fixture resolves\033[0m\n" "$dep"
        printf "      (the PR CI consumer check, hack/fixtures.sh consumers in cli and opm-operator, fails on it; FIX=1 against a seeded registry adds it)\n"
        continue
      fi
      mv_=$(pin_of "${fixmod[$path]}" "$dep")
      [ "$cv" = "$mv_" ] && continue
      set_pin "$f" "$dep" "$mv_"
      printf "    %s: %s -> %s (follows the fixture)\n" "$dep" "$cv" "$mv_"
    done < <(grep -oP '^\s*"\K[^"]+(?=":\s*\{)' "${fixmod[$path]}")
  done
}

for f in cli/tests/e2e/testdata/operator-owned/cue.mod/module.cue cli/examples/cue.mod/module.cue opm-operator/test/fixtures/modulepackages/*/cue.mod/module.cue; do
  [ -f "$f" ] || continue
  printf "==> Consumer \033[1;36m%s\033[0m (text re-pin, no tidy)\n" "${f%/cue.mod/module.cue}"
  follow_fixtures "$f"
done
# moduleinstance.yaml files and the config/samples ModuleInstance follow through
# the operator's own pin task.
if [ -f opm-operator/Taskfile.yml ]; then
  printf "==> opm-operator: task examples:pin\n"; (cd opm-operator && task examples:pin >/dev/null 2>&1) || printf "    \033[1;31mexamples:pin failed; run it in opm-operator\033[0m\n"
fi
printf "Done.\n"
