#!/usr/bin/env bash
# @-mention file suggestions that descend into nested git repos.
#
# Claude Code's built-in picker stops at a nested .git boundary, so in a
# workspace-of-repos layout it only ever offers the parent repo's own files
# (anthropics/claude-code#94991, open as of 2026-09-17). This replaces the
# source: ripgrep is run once in the workspace and once inside each nested
# repo, so every repo's own ignore rules still apply.
#
# Wired up via the `fileSuggestion` setting in user settings (see README.md).
# stdin: JSON from Claude Code (cwd, and a query when the picker has one).
# stdout: newline-separated paths, relative to cwd.

set -uo pipefail

payload=$(cat 2>/dev/null || true)

extract() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$payload" | head -1; }

cwd=$(extract cwd); [[ -d ${cwd:-} ]] || cwd=$PWD
query=$(extract query)

RG=$(command -v rg || echo /usr/bin/rg)
[[ -x $RG ]] || exit 0

list_repo() { # $1 = dir, $2 = path prefix
  "$RG" --files --hidden --follow --glob '!.git/' --glob '!node_modules/' \
        --max-depth 12 -- "$1" 2>/dev/null |
    sed "s|^$1/|$2|"
}

{
  list_repo "$cwd" ""
  while IFS= read -r g; do
    d=${g%/.git}
    [[ $d == "$cwd" ]] && continue
    list_repo "$d" "${d#"$cwd"/}/"
  done < <(find "$cwd" -mindepth 2 -maxdepth 3 -name .git -print 2>/dev/null)
} | if [[ -n $query ]]; then
      # fuzzy: the query's characters in order, anywhere in the path
      pat=$(sed 's/./&.*/g' <<<"$query")
      grep -i -E "$pat" || true
    else
      cat
    fi | awk '!seen[$0]++' | head -2000
