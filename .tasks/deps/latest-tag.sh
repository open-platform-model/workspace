#!/usr/bin/env bash
# Print the newest CONSUMABLE release of a workspace repo:
#   latest-tag.sh <repo> <prefix> <asset>[,<asset>...] [version]
# Candidates are the repo's git tags matching <prefix>, read anonymously with
# git ls-remote. Prereleases count (the v2 line ships alpha, then beta, then GA);
# `-0.dev.` branch builds do not. Walking newest first, the first candidate whose
# every <asset> answers 200 at
#   https://github.com/open-platform-model/<repo>/releases/download/<prefix><ver>/<asset>
# wins. That is the URL CI downloads anonymously, so a release still in draft
# (cli and opm-operator publish draft-first) and a published release without
# the asset (cli v1.0.0-alpha.21) both answer 404 and are skipped, on stderr.
# With [version], only that version is checked: an explicit pin is verified too.
# Only a 404 means "not consumable"; any other answer (network, 5xx, 429)
# aborts, so a hiccup never silently pins an older version. At most the newest
# 10 candidates are checked. The version is echoed WITHOUT the prefix and
# without a leading `v`.
set -euo pipefail
die() { printf 'latest-tag: %s\n' "$*" >&2; exit 1; }
[ $# -ge 3 ] || die "usage: latest-tag.sh <repo> <prefix> <asset>[,<asset>...] [version]"
repo="$1"; prefix="$2"; IFS=, read -ra assets <<<"$3"; want="${4:-}"
usage_assets="an <asset> list is required (comma-separated, no empty names)"
[ "${#assets[@]}" -gt 0 ] || die "$usage_assets"
for a in "${assets[@]}"; do [ -n "$a" ] || die "$usage_assets"; done
max=10
command -v curl >/dev/null 2>&1 || die "curl is required"

if [ -n "$want" ]; then
  cands="${want#v}"
else
  tags=$(git ls-remote --tags --refs "https://github.com/open-platform-model/${repo}" "refs/tags/${prefix}*") \
    || die "cannot list ${prefix}* tags of ${repo}"
  # sed -n "1,Np" reads all of its input (no SIGPIPE under pipefail).
  cands=$(printf '%s\n' "$tags" \
    | awk -F'refs/tags/' 'NF > 1 {print $2}' \
    | { grep -v -- '-0\.dev\.' || true; } \
    | sed "s/^${prefix}//; s/^v//" \
    | sed "s/-/~/" | sort -rV | sed "s/~/-/" | sed -n "1,${max}p")
  [ -n "$cands" ] || die "no ${prefix}* release tags in ${repo}"
fi

# HTTP status of an anonymous HEAD, following the redirect to the asset host.
# -q first: never read ~/.curlrc, so the answer does not depend on the caller.
# A stalled connection times out and ends as '000', which aborts below.
status() {
  curl -q -s -o /dev/null -w '%{http_code}' -I -L --connect-timeout 10 --max-time 60 \
    --retry 3 --retry-delay 2 "$1" || true
}

for v in $cands; do
  missing=""
  for a in "${assets[@]}"; do
    code=$(status "https://github.com/open-platform-model/${repo}/releases/download/${prefix}${v}/${a}")
    case "$code" in
      200) ;;
      404) missing="$a"; break ;;
      *) die "checking ${prefix}${v}/${a} answered '${code}'; refusing to guess" ;;
    esac
  done
  if [ -z "$missing" ]; then echo "$v"; exit 0; fi
  printf '    \033[1;33mskip\033[0m %s%s: %s not downloadable (release still a draft, or asset never attached)\n' \
    "$prefix" "$v" "$missing" >&2
done
[ -z "$want" ] || die "${prefix}${want#v} is not a consumable ${repo} release"
die "none of the newest ${max} ${prefix}* tags in ${repo} is a consumable release"
