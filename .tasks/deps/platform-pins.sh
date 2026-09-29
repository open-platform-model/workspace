#!/usr/bin/env bash
# Bump the versions that Platform definitions pin OUTSIDE a cue.mod file:
#   opm-operator/config/samples/opmodel.dev_v1alpha1_platform.yaml  (e2e specs apply it verbatim)
#   cli/hack/kind-platform.yaml                                      (cluster Platform singleton the
#       kind dev flow applies; its header says it mirrors cli/hack/platform/, a real cue.mod that
#       deps:update:modules bumps, and this keeps the YAML side of that mirror in step)
# The two are documented as kept aligned; this is the one place that does it. The
# library parity platform is NOT here: since 0019 D5 it embeds its catalog by import
# and carries no version; library's own `task cue:deps:update` moves its cue.mod.
# Source of truth: catalog_opm's release tags (opm-vX.Y.Z, k8s-vX.Y.Z).
set -euo pipefail
here=$(dirname "$0")
opm=$("$here/latest-tag.sh" catalog_opm opm-v)
k8s=$("$here/latest-tag.sh" catalog_opm k8s-v)
printf "==> Platform pins: catalogs/opm \033[0;32m%s\033[0m, catalogs/k8s \033[0;32m%s\033[0m\n" "$opm" "$k8s"

# Rewrite the `version: "..."` that follows a given subscription key line.
# $1 file, $2 key regex, $3 version. Reports old -> new, or unchanged.
bump_after_key() {
  local file="$1" key="$2" ver="$3" old
  old=$(awk -v k="$key" '$0 ~ k {f=1; next} f && /version:/ {match($0, /"[^"]+"/); print substr($0, RSTART+1, RLENGTH-2); exit}' "$file")
  if [ -z "$old" ]; then printf "    %s: \033[1;31mkey %s not found\033[0m\n" "$file" "$key"; return; fi
  if [ "$old" = "$ver" ]; then printf "    %s [%s]: \033[2m%s (unchanged)\033[0m\n" "$file" "$key" "$old"; return; fi
  awk -v k="$key" -v v="$ver" '$0 ~ k {f=1} f && /version:/ {sub(/"[^"]+"/, "\"" v "\""); f=0} {print}' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  printf "    %s [%s]: \033[1;33m%s\033[0m -> \033[0;32m%s\033[0m\n" "$file" "$key" "$old" "$ver"
}

bump_after_key opm-operator/config/samples/opmodel.dev_v1alpha1_platform.yaml 'opmodel.dev/catalogs/opm@v4:' "$opm"
bump_after_key opm-operator/config/samples/opmodel.dev_v1alpha1_platform.yaml 'opmodel.dev/catalogs/k8s@v1:' "$k8s"

# Same document shape, same scalar subscriptions: the kind dev cluster's
# Platform singleton. It must agree with cli/hack/platform/, or the operator
# and the CLI tests resolve different catalog builds from the same dev cluster.
bump_after_key cli/hack/kind-platform.yaml 'opmodel.dev/catalogs/opm@v4:' "$opm"
bump_after_key cli/hack/kind-platform.yaml 'opmodel.dev/catalogs/k8s@v1:' "$k8s"

printf "Done.\n"
