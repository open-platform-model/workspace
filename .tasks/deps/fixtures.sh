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
#   opm-operator  test/fixtures/modulepackages/*/cue.mod (sed re-pin, no tidy),
#                 moduleinstance.yaml + config/samples (task examples:pin)
#   cli           tests/e2e/testdata/operator-owned/cue.mod, examples/cue.mod
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
    printf "    version: \033[1;33m%s\033[0m -> \033[0;32m%s\033[0m (%s)\n" "$cur" "$next" "$path"
  fi
done

if [ "${#newver[@]}" -eq 0 ]; then
  printf "No fixture moved; nothing to re-pin.\n"
  exit 0
fi

# repin_cuemod <file>: re-point every fixture dep pinned in a cue.mod at the
# module's new declared version (sed only; these are not path deps, `cue mod
# tidy` cannot move them).
repin_cuemod() {
  local f="$1" path old
  [ -f "$f" ] || return 0
  for path in "${!newver[@]}"; do
    grep -q "\"$path\"" "$f" || continue
    old=$(grep -FA5 "\"$path\"" "$f" | grep -oP 'v:\s*"\K[^"]+' | head -1)
    awk -v p="\"$path\"" -v v="v${newver[$path]}" 'index($0,p) {f=1} f && /v: "/ {sub(/"[^"]+"/, "\"" v "\""); f=0} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    printf "==> %s: %s \033[1;33m%s\033[0m -> \033[0;32mv%s\033[0m\n" "$f" "$path" "$old" "${newver[$path]}"
  done
}
# cli consumers that pin the podinfo fixture by version.
repin_cuemod cli/tests/e2e/testdata/operator-owned/cue.mod/module.cue
repin_cuemod cli/examples/cue.mod/module.cue

for pkg in opm-operator/test/fixtures/modulepackages/*/; do
  pkg="${pkg%/}"; f="$pkg/cue.mod/module.cue"; [ -f "$f" ] || continue
  printf "==> Modulepackage \033[1;36m%s\033[0m (sed re-pin, no tidy)\n" "$pkg"
  for path in "${!newver[@]}"; do
    grep -q "\"$path\"" "$f" || continue
    old=$(grep -FA5 "\"$path\"" "$f" | grep -oP 'v:\s*"\K[^"]+' | head -1)
    awk -v p="\"$path\"" -v v="v${newver[$path]}" 'index($0,p) {f=1} f && /v: "/ {sub(/"[^"]+"/, "\"" v "\""); f=0} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    printf "    %s: \033[1;33m%s\033[0m -> \033[0;32mv%s\033[0m\n" "$path" "$old" "${newver[$path]}"
    # core/catalog pins follow the module they instantiate
    mod="opm-operator/test/fixtures/modules/$(basename "$pkg")/cue.mod/module.cue"
    for dep in $(grep -oP '^\s*"\Kopmodel.dev/[^"]+(?=":\s*\{)' "$f"); do
      mv_=$(grep -FA5 "\"$dep\"" "$mod" | grep -oP 'v:\s*"\K[^"]+' | head -1); [ -n "$mv_" ] || continue
      awk -v p="\"$dep\"" -v v="$mv_" 'index($0,p) {f=1} f && /v: "/ {sub(/"[^"]+"/, "\"" v "\""); f=0} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      printf "    %s: -> %s (follows the module)\n" "$dep" "$mv_"
    done
  done
done
# moduleinstance.yaml files and the config/samples ModuleInstance follow through
# the operator's own pin task.
if [ -f opm-operator/Taskfile.yml ]; then
  printf "==> opm-operator: task examples:pin\n"; (cd opm-operator && task examples:pin >/dev/null 2>&1) || printf "    \033[1;31mexamples:pin failed; run it in opm-operator\033[0m\n"
fi
printf "Done.\n"
