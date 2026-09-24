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
# stdout: newline-separated paths relative to cwd, best match first, then
# shallowest first; folders carry a trailing /. Claude Code shows them in this
# order and does not re-rank them.

set -uo pipefail

payload=$(cat 2>/dev/null || true)

extract() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$payload" | head -1; }

cwd=$(extract cwd); [[ -d ${cwd:-} ]] || cwd=$PWD
query=$(extract query)

# A real ripgrep binary, else the one bundled in the Claude binary (invoked as
# argv0 "rg"). An interactive shell's `rg` is often a function wrapping the
# latter, which a script does not inherit.
if RG=$(type -P rg); then
  rg() { "$RG" "$@"; }
else
  CC=${CLAUDE_CODE_EXECPATH:-$HOME/.local/bin/claude}
  if [[ ! -x $CC ]]; then
    echo "file-suggestion: no ripgrep found (install ripgrep)" >&2
    exit 0
  fi
  rg() { (exec -a rg "$CC" "$@"); }
fi

list_repo() { # $1 = dir, $2 = path prefix
  rg --files --hidden --follow --glob '!.git/' --glob '!node_modules/' \
     --max-depth 12 -- "$1" 2>/dev/null |
    sed "s|^$1/|$2|"
}

files=$(
  {
    list_repo "$cwd" ""
    while IFS= read -r g; do
      d=${g%/.git}
      [[ $d == "$cwd" ]] && continue
      list_repo "$d" "${d#"$cwd"/}/"
    done < <(find "$cwd" -mindepth 2 -maxdepth 3 -name .git -print 2>/dev/null)
  } | awk '!seen[$0]++'
)

# each file plus every parent folder, shallowest first, folders before files
awk -F/ '{
  d = ""
  for (i = 1; i < NF; i++) { d = d $i "/"; if (!seen[d]++) print i "\t0\t" d }
  print NF "\t1\t" $0
}' <<<"$files" | sort -s -n -k1,1 -k2,2 | cut -f3- |
  if [[ -n $query ]]; then
      # rank by match quality, keeping the depth order within each rank:
      # 0 a segment equals the query, 1 a segment starts with it, 2 it occurs
      # as a substring, 3 its characters occur in order (fuzzy)
      awk -v q="$query" 'BEGIN { q = tolower(q) } {
        p = tolower($0); n = split(p, seg, "/"); rank = -1
        for (i = 1; i <= n; i++) if (seg[i] == q) { rank = 0; break }
        if (rank < 0) for (i = 1; i <= n; i++) if (index(seg[i], q) == 1) { rank = 1; break }
        if (rank < 0 && index(p, q)) rank = 2
        if (rank < 0) {
          rest = p
          for (i = 1; i <= length(q); i++) {
            j = index(rest, substr(q, i, 1)); if (!j) next
            rest = substr(rest, j + 1)
          }
          rank = 3
        }
        print rank "\t" $0
      }' | sort -s -n -k1,1 | cut -f2-
    else
      cat
    fi | head -2000
exit 0
