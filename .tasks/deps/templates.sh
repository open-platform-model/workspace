#!/usr/bin/env bash
# Update the CUE deps of the cli's official templates (cli/templates/*/) and
# bump the patch version of every template whose cue.mod/module.cue changed, so
# the cli PR that `task deps:update` produces passes the template publish gate
# (a template whose content differs from its published version must declare a
# new one) and the next cli release publishes the new pins.
#
# A changed template is bumped only when GHCR already holds its declared
# version. A declared version GHCR does not hold yet (bumped earlier in the
# same release cycle) is still pending and carries the new pins; bumping it
# again would skip a version for nothing. The bump goes one patch above the
# highest published stable version of the template's major (which is the
# declared one when the tree is current), so it never lands on a published
# version.
#
# GHCR is read anonymously, at the path cue uses for the canonical mapping
# (ghcr.io/open-platform-model/<module path>). A 403 or 404 reads as "no
# versions", as in cue's own registry client: GHCR answers 403 for a package
# it does not know. A brand-new template therefore never gets bumped here.
# Manual step after its first publish: make the template's GHCR package
# public (package settings), or `opm module init` cannot fetch it and the
# cli publish gate fails closed for it. Any other answer fails the run.
#
# Needs cue, curl, and opm (`opm module version set`) when a bump is due.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091 # lib.sh is checked on its own
. "$here/lib.sh"

ghcr=https://ghcr.io
stable_re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
red() { printf "    \033[1;31m%s\033[0m\n" "$*"; }

# pin_of <file> <dep>: the v: <file> pins <dep> at (empty when absent).
pin_of() { grep -FA5 "\"$2\"" "$1" | grep -oP 'v:\s*"\K[^"]+' | head -1 || true; }

# http <out> <url> [curl args...]: the HTTP status ('000' when no answer).
http() {
  local out=$1 url=$2; shift 2
  curl -q -sS -o "$out" -D "$out.headers" -w '%{http_code}' --connect-timeout 10 --max-time 60 \
    --retry 3 --retry-delay 2 "$@" "$url" 2>/dev/null || true
}

# published <module path>: the published stable versions of the path's major,
# bare and ascending, one per line. Returns 1 on an unexpected answer; sets
# unknown=1 when GHCR does not serve the package anonymously.
unknown=0
published() {
  local path=$1 repo major code tok url pages=0
  repo="open-platform-model/${path%@v*}"; major="${path##*@v}"
  unknown=0
  : >"$work/tags"
  code=$(http "$work/token" "${ghcr}/token?scope=repository:${repo}:pull&service=ghcr.io")
  case $code in
    200) tok=$(grep -oP '"token"\s*:\s*"\K[^"]+' "$work/token") || return 1 ;;
    403 | 404) unknown=1; return 0 ;;
    *) printf 'token request answered %s' "$code" >"$work/why"; return 1 ;;
  esac
  url="/v2/${repo}/tags/list?n=1000"
  while [ -n "$url" ]; do
    pages=$((pages + 1))
    [ "$pages" -le 20 ] || { printf 'more than 20 tag pages' >"$work/why"; return 1; }
    code=$(http "$work/page" "${ghcr}${url}" -H "Authorization: Bearer ${tok}")
    case $code in
      200) grep -oP '"v[^"]*"' "$work/page" | tr -d '"' >>"$work/tags" || true ;;
      403 | 404) [ "$pages" -eq 1 ] || { printf 'tags page %d answered %s' "$pages" "$code" >"$work/why"; return 1; }
        unknown=1; break ;;
      *) printf 'tags list answered %s' "$code" >"$work/why"; return 1 ;;
    esac
    url=$(sed -En 's/^[Ll]ink: *<([^>]*)>; *rel="next".*$/\1/p' "$work/page.headers" | tr -d '\r')
  done
  sed -n "s/^v\(${major}\.[0-9]*\.[0-9]*\)$/\1/p" "$work/tags" | { grep -E "$stable_re" || true; } \
    | sort -t. -k1,1n -k2,2n -k3,3n -u
}

# above <a> <b>: 0 when stable version a is above stable version b.
above() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)" = "$1" ]
}

for moddir in cli/templates/*/cue.mod; do
  [ -d "$moddir" ] || continue
  dir=$(dirname "$moddir"); mod="$moddir/module.cue"
  printf "==> Updating template deps in \033[1;36m%s\033[0m\n" "$dir"
  deps=$(sed -n '/^deps: {$/,/^}$/p' "$mod" 2>/dev/null | grep -oP '^\s*"\K[^"]+(?=":\s*\{)') || true
  if [ -z "$deps" ]; then printf "    (no deps)\n"; continue; fi
  cp "$mod" "$work/before"

  for dep in $deps; do
    (cd "$dir" && cue mod get "$dep" >/dev/null 2>&1) || true
  done
  # A bump can add or drop requirements; the template publish gate refuses a
  # template that is not tidy (cli publish-templates.sh).
  tidy_ok=1
  (cd "$dir" && cue mod tidy) || tidy_ok=0
  # Report against the file as it was before any get: one get can move a
  # sibling dep (MVS), so reading "old" between gets would hide that move.
  for dep in $deps; do
    old=$(pin_of "$work/before" "$dep"); new=$(pin_of "$mod" "$dep")
    if [ -n "$new" ] && [ "$old" != "$new" ]; then
      printf "    %s: \033[1;33m%s\033[0m -> \033[0;32m%s\033[0m\n" "$dep" "$old" "$new"
    else
      printf "    %s: \033[2m%s (unchanged)\033[0m\n" "$dep" "$old"
    fi
  done
  [ "$tidy_ok" = 1 ] || { red "cue mod tidy failed in $dir"; failed=1; continue; }
  cmp -s "$work/before" "$mod" && continue

  if ! cur=$(cd "$dir" && cue eval ./identity --out text -e Version) \
    || ! path=$(cd "$dir" && cue eval ./identity --out text -e ModulePath); then
    red "cannot read $dir/identity (Version, ModulePath)"; failed=1; continue
  fi
  if ! [[ $cur =~ $stable_re ]]; then
    red "version $cur is not a stable X.Y.Z; set the next one by hand (opm module version set)"; failed=1; continue
  fi
  : >"$work/why"
  if ! published "$path" >"$work/pub"; then
    red "cannot list the published versions of $path: $(cat "$work/why")"; failed=1; continue
  fi
  pub=$(cat "$work/pub"); high=$(tail -n 1 <<<"$pub")
  if [ "$unknown" = 1 ]; then
    printf "    version: \033[2m%s (GHCR serves no %s anonymously: a new template keeps its first version; after its first publish, make the package public)\033[0m\n" "$cur" "$path"
  elif grep -qxF "$cur" <<<"$pub"; then
    next=$(next_patch "$high")
    command -v opm >/dev/null 2>&1 || { red "opm is required to bump $dir to $next"; failed=1; continue; }
    (cd "$dir" && opm module version set "$next" . >/dev/null)
    printf "    version: \033[1;33m%s\033[0m -> \033[0;32m%s\033[0m (%s; v%s is published)\n" "$cur" "$next" "$path" "$cur"
  elif [ -n "$high" ] && ! above "$cur" "$high"; then
    red "version $cur is unpublished but not above the published v$high of $path; set it above v$high by hand"; failed=1
  else
    printf "    version: \033[2m%s (not published yet; the pending version carries the new pins)\033[0m\n" "$cur"
  fi
done

[ "$failed" = 0 ] || { printf "templates: some templates need attention (see above)\n" >&2; exit 1; }
printf "Done.\n"
