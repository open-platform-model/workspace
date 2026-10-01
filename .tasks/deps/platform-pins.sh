#!/usr/bin/env bash
# Bump the versions that Platform definitions pin OUTSIDE a cue.mod file:
#   opm-operator/config/samples/opmodel.dev_v1alpha1_platform.yaml  (e2e specs apply it verbatim)
#   cli/hack/kind-platform.yaml                                      (cluster Platform singleton the
#       kind dev flow applies; its header says it mirrors cli/hack/platform/, a real cue.mod that
#       deps:update:modules bumps, and this keeps the YAML side of that mirror in step)
# The two are documented as kept aligned; this is the one place that does it. The
# library parity platform is NOT here: since 0019 D5 it embeds its catalog by import
# and carries no version; library's own `task cue:deps:update` moves its cue.mod.
# Source of truth: cli/hack/platform/cue.mod/module.cue, which deps:update:modules
# has just resolved with `cue mod get` under the active CUE_REGISTRY (GHCR under
# the canonical mapping). Reading it (not catalog_opm's git tags) makes each YAML
# key an exact mirror of the same cue.mod key: same major (the @v<major> key),
# cue's stable-before-prerelease choice, and only versions the registry served.
# A YAML that lacks a key fails the run. Offline; no registry or GitHub call.
set -euo pipefail
mirror=cli/hack/platform/cue.mod/module.cue
opm_key='opmodel.dev/catalogs/opm@v4'
k8s_key='opmodel.dev/catalogs/k8s@v1'

# Bare version (no leading v) that $mirror pins for dep key $1; exits when absent.
pinned() {
  local v
  [ -f "$mirror" ] || { printf "platform-pins: %s not found (is cli checked out?)\n" "$mirror" >&2; exit 1; }
  v=$(grep -FA5 "\"$1\"" "$mirror" | grep -oP 'v:\s*"\K[^"]+' | sed -n 1p) || true
  [ -n "$v" ] || { printf "platform-pins: %s does not pin %s (major moved? update the key here)\n" "$mirror" "$1" >&2; exit 1; }
  echo "${v#v}"
}
opm=$(pinned "$opm_key")
k8s=$(pinned "$k8s_key")
printf "==> Platform pins (from %s): catalogs/opm \033[0;32m%s\033[0m, catalogs/k8s \033[0;32m%s\033[0m\n" "$mirror" "$opm" "$k8s"

# Rewrite the `version: "..."` that follows a given subscription key line.
# $1 file, $2 key regex, $3 version. Reports old -> new, or unchanged. A missing
# key is recorded and fails the run at the end (the other files still sync).
missing=0
bump_after_key() {
  local file="$1" key="$2" ver="$3" old
  old=$(awk -v k="$key" '$0 ~ k {f=1; next} f && /version:/ {match($0, /"[^"]+"/); print substr($0, RSTART+1, RLENGTH-2); exit}' "$file")
  if [ -z "$old" ]; then
    printf "    %s: \033[1;31mkey %s not found\033[0m\n" "$file" "$key"
    missing=$((missing + 1)); return
  fi
  if [ "$old" = "$ver" ]; then printf "    %s [%s]: \033[2m%s (unchanged)\033[0m\n" "$file" "$key" "$old"; return; fi
  awk -v k="$key" -v v="$ver" '$0 ~ k {f=1} f && /version:/ {sub(/"[^"]+"/, "\"" v "\""); f=0} {print}' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  printf "    %s [%s]: \033[1;33m%s\033[0m -> \033[0;32m%s\033[0m\n" "$file" "$key" "$old" "$ver"
}

bump_after_key opm-operator/config/samples/opmodel.dev_v1alpha1_platform.yaml "${opm_key}:" "$opm"
bump_after_key opm-operator/config/samples/opmodel.dev_v1alpha1_platform.yaml "${k8s_key}:" "$k8s"

# Same document shape, same scalar subscriptions: the kind dev cluster's
# Platform singleton. It must agree with cli/hack/platform/, or the operator
# and the CLI tests resolve different catalog builds from the same dev cluster.
bump_after_key cli/hack/kind-platform.yaml "${opm_key}:" "$opm"
bump_after_key cli/hack/kind-platform.yaml "${k8s_key}:" "$k8s"

if [ "$missing" -gt 0 ]; then
  printf "platform-pins: %d key(s) not found; the YAML no longer matches the keys here (major moved?)\n" "$missing" >&2
  exit 1
fi
printf "Done.\n"
