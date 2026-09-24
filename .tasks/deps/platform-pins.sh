#!/usr/bin/env bash
# Bump the versions that Platform definitions pin OUTSIDE a cue.mod file:
#   opm-operator/config/samples/opmodel.dev_v1alpha1_platform.yaml  (e2e specs apply it verbatim)
#   cli/hack/kind-platform.yaml                                      (cluster Platform singleton the
#       kind dev flow applies; its header says it mirrors templates.go, and before it was listed
#       here nothing made that true — it silently drifted three catalog releases behind)
#   cli/internal/config/templates.go                                 (seeded ~/.opm/platform module:
#       DefaultCorePin + DefaultCatalogPins, rendered into the embedded cue.mod/module.cue;
#       cli/internal/platform/spec_test.go and the legacy data literal derive from these, no
#       separate bump. cli/hack/platform/cue.mod is a real cue.mod: deps:update:modules bumps it.)
# The two are documented as kept aligned; this is the one place that does it. The
# library parity platform is NOT here: since 0019 D5 it embeds its catalog by import
# and carries no version; library's own `task cue:deps:update` moves its cue.mod.
# Source of truth: catalog_opm's release tags (opm-vX.Y.Z, k8s-vX.Y.Z) and core's (vX.Y.Z).
set -euo pipefail
here=$(dirname "$0")
opm=$("$here/latest-tag.sh" catalog_opm opm-v)
k8s=$("$here/latest-tag.sh" catalog_opm k8s-v)
core=$("$here/latest-tag.sh" core v)
printf "==> Platform pins: catalogs/opm \033[0;32m%s\033[0m, catalogs/k8s \033[0;32m%s\033[0m, core \033[0;32m%s\033[0m\n" "$opm" "$k8s" "$core"

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
# Platform singleton. It must agree with templates.go below, or the operator
# and the CLI resolve different catalog builds from the same dev cluster.
bump_after_key cli/hack/kind-platform.yaml 'opmodel.dev/catalogs/opm@v4:' "$opm"
bump_after_key cli/hack/kind-platform.yaml 'opmodel.dev/catalogs/k8s@v1:' "$k8s"

# templates.go pins the seeded platform module's deps as Go literals (cue.mod
# wants the "v" prefix): DefaultCatalogPins carries one line per catalog with a
# trailing key comment, DefaultCorePin one const. Each is matched by its key.
# $1 file, $2 key regex (the line must contain it), $3 version (bare SemVer).
bump_go_pin() {
  local file="$1" key="$2" ver="v$3" old
  old=$(grep -P "$key" "$file" | grep -oP '"v[^"]+"' | head -1 | tr -d '"')
  if [ -z "$old" ]; then printf "    %s: \033[1;31mkey %s not found\033[0m\n" "$file" "$key"; return; fi
  if [ "$old" = "$ver" ]; then printf "    %s [%s]: \033[2m%s (unchanged)\033[0m\n" "$file" "$key" "$old"; return; fi
  awk -v k="$key" -v v="$ver" '$0 ~ k {sub(/"v[^"]+"/, "\"" v "\"")} {print}' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  printf "    %s [%s]: \033[1;33m%s\033[0m -> \033[0;32m%s\033[0m\n" "$file" "$key" "$old" "$ver"
}

f=cli/internal/config/templates.go
bump_go_pin "$f" '// opmodel.dev/catalogs/opm@v4$' "$opm"
bump_go_pin "$f" '// opmodel.dev/catalogs/k8s@v1$' "$k8s"
bump_go_pin "$f" '^const DefaultCorePin = ' "$core"
printf "Done.\n"
