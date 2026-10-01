#!/usr/bin/env bash
# Bump the pinned `opm` CLI release that CI installs, in every repo that pins one:
#   catalog_opm  .github/workflows/*.yml   OPM_CLI_VERSION: 'vX'   (checksummed tarball)
#   modules      .github/workflows/*.yml   OPM_CLI_VERSION: 'vX'
#   opm-modules  .github/workflows/*.yml   OPM_CLI_VERSION: 'vX'   (personal fleet, when checked out)
#   opm-operator .github/workflows/*.yml   go install .../cli/cmd/opm@vX
# core pins no CLI (its CI is cue-only); it is listed so nobody wonders.
# Usage: opm-cli.sh [vX.Y.Z]
#   default: cli's newest release whose opm-linux-amd64.tar.gz and checksums.txt
#   download anonymously (what CI fetches); an explicit version is verified the
#   same way. opm-operator's `go install` needs only the tag, but takes the same
#   version so every repo pins one CLI.
set -euo pipefail
here=$(dirname "$0")
ver="v$("$here/latest-tag.sh" cli v opm-linux-amd64.tar.gz,checksums.txt "${1:-}")"
if [ -n "${1:-}" ]; then how="explicit, verified"; else how="newest published release"; fi
printf "==> opm CLI pin: \033[0;32m%s\033[0m (%s)\n" "$ver" "$how"
report() { # $1 file, $2 old versions (space-separated)
  if [ "$2" = "$ver" ]; then printf "    %s: \033[2m%s (unchanged)\033[0m\n" "$1" "$2"
  else printf "    %s: \033[1;33m%s\033[0m -> \033[0;32m%s\033[0m\n" "$1" "$2" "$ver"; fi
}
for f in catalog_opm/.github/workflows/*.yml modules/.github/workflows/*.yml \
         opm-modules/.github/workflows/*.yml; do
  grep -q "OPM_CLI_VERSION: '" "$f" 2>/dev/null || continue
  old=$(grep -oP "OPM_CLI_VERSION: '\K[^']+" "$f" | sort -u | tr '\n' ' ' | sed 's/ $//')
  sed -E -i "s/(OPM_CLI_VERSION: ')v[^']*/\1${ver}/" "$f"
  report "$f" "$old"
done
for f in opm-operator/.github/workflows/*.yml; do
  grep -q "cli/cmd/opm@v" "$f" 2>/dev/null || continue
  old=$(grep -oP "cli/cmd/opm@\K[^[:space:]]+" "$f" | sort -u | tr '\n' ' ' | sed 's/ $//')
  sed -E -i "s#(cli/cmd/opm@)v[^[:space:]]*#\1${ver}#" "$f"
  report "$f" "$old"
done
printf "    core: no CLI pin (cue-only CI)\n"
printf "Done.\n"
