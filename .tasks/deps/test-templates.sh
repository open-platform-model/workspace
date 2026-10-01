#!/usr/bin/env bash
# Offline table test for templates.sh. Run from anywhere:
#   .tasks/deps/test-templates.sh
# cue, opm and curl are PATH shims: cue moves the deps FAKE_MOVE names and
# reads identity/identity.cue, opm rewrites its Version, curl answers GHCR's
# token and tags/list with fake data. No network, no registry, no real module.
# Exits non-zero when any case fails.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ts="$here/templates.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/nobin"

# cue shim. FAKE_MOVE: "<dep>=<version> ..." applied by `cue mod get <dep>`.
# FAKE_TIDY_RC: exit status of `cue mod tidy`.
cat >"$root/bin/cue" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "mod get")
    for m in ${FAKE_MOVE:-}; do
      [ "${m%%=*}" = "$3" ] || continue
      awk -v p="\"$3\"" -v v="${m#*=}" 'index($0,p) {f=1} f && /v: "/ {sub(/"[^"]+"/, "\"" v "\""); f=0} {print}' \
        cue.mod/module.cue >cue.mod/module.cue.tmp && mv cue.mod/module.cue.tmp cue.mod/module.cue
    done ;;
  "mod tidy") exit "${FAKE_TIDY_RC:-0}" ;;
  "eval ./identity") sed -n "s/^${6}: \"\(.*\)\"$/\1/p" identity/identity.cue ;;
  *) echo "cue shim: unexpected $*" >&2; exit 2 ;;
esac
EOF
# opm shim: `opm module version set <v> .` rewrites the identity Version.
cat >"$root/bin/opm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$OPM_LOG"
[ "$1 $2 $3" = "module version set" ] || { echo "opm shim: unexpected $*" >&2; exit 2; }
sed -i "s/^Version: \".*\"$/Version: \"$4\"/" identity/identity.cue
EOF
# curl shim. TOKEN_CODE (default 200) answers the token; TAGS_CODE (default
# 200) the tags list. PAGE1 / PAGE2 hold space-separated tags; a non-empty
# PAGE2 makes page 1 carry a Link header to it.
cat >"$root/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
out=/dev/null; hdr=/dev/null; url="${*: -1}"
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift ;; -D) hdr=$2; shift ;; esac; shift
done
json() { printf '{"name":"x","tags":['; local s=""; for t in $1; do printf '%s"%s"' "$s" "$t"; s=,; done; printf ']}'; }
: >"$hdr"
case "$url" in
  *"/token?"*) code=${TOKEN_CODE:-200}; printf '{"token":"tok"}' >"$out" ;;
  *"/tags/list"*"last="*) code=${TAGS_CODE:-200}; json "${PAGE2:-}" >"$out" ;;
  *"/tags/list"*)
    code=${TAGS_CODE:-200}; json "${PAGE1:-}" >"$out"
    [ -z "${PAGE2:-}" ] || printf 'Link: </v2/x/tags/list?n=1000&last=p1>; rel="next"\r\n' >"$hdr" ;;
  *) code=404 ;;
esac
printf '%s' "$code"
[ "$code" = 000 ] && exit 7
exit 0
EOF
chmod +x "$root/bin/cue" "$root/bin/opm" "$root/bin/curl"
ln -s "$root/bin/cue" "$root/nobin/cue"; ln -s "$root/bin/curl" "$root/nobin/curl"
export CURL_LOG="$root/curl.log" OPM_LOG="$root/opm.log"
PATH0=$PATH

pass=0
fail=0
check() { # $1 name, $2 0|1 condition result
  if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; fi
}

# mk <version>: a scratch workspace with one template, minimal, at <version>.
mk() {
  ws="$root/ws$((++n))"; t="$ws/cli/templates/minimal"
  mkdir -p "$t/cue.mod" "$t/identity"
  printf 'module: "opmodel.dev/templates/minimal@v1"\ndeps: {\n\t"opmodel.dev/core@v2": {\n\t\tv: "v2.0.0-beta.1"\n\t}\n}\n' \
    >"$t/cue.mod/module.cue"
  printf 'package identity\n\nModulePath: "opmodel.dev/templates/minimal@v1"\nVersion: "%s"\n' "$1" >"$t/identity/identity.cue"
}
ver() { sed -n 's/^Version: "\(.*\)"$/\1/p' "$t/identity/identity.cue"; }

# run <name> <want rc> <want version> <stdout+stderr substring or ""> [env...]
run() {
  local name="$1" wrc="$2" wver="$3" wout="$4" rc ok=1
  shift 4
  : >"$CURL_LOG"; : >"$OPM_LOG"
  (cd "$ws" && env PATH="$root/bin:$PATH0" "$@" "$ts" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >"$root/out"; exit "${PIPESTATUS[0]}"); rc=$?
  [ "$rc" = "$wrc" ] && [ "$(ver)" = "$wver" ] && { [ -z "$wout" ] || grep -qF -- "$wout" "$root/out"; } && ok=0
  check "$name (rc=$rc version=$(ver) out=$(tr '\n' ' ' <"$root/out"))" "$ok"
}
n=0
mv_=FAKE_MOVE=opmodel.dev/core@v2=v2.0.0-beta.2

mk 1.0.3; run "unchanged cue.mod: no bump" 0 1.0.3 "(unchanged)"
check "unchanged cue.mod: no GHCR call" "$(($(wc -c <"$CURL_LOG") == 0 ? 0 : 1))"

mk 1.0.3; run "moved, declared is published: next patch" 0 1.0.4 "1.0.3 -> 1.0.4" "$mv_" PAGE1="v1.0.2 v1.0.3"
grep -qF 'module version set 1.0.4 .' "$OPM_LOG"; check "bump goes through opm module version set" $?
grep -q '^-q ' "$CURL_LOG" && ! grep -qv '^-q ' "$CURL_LOG"; check "every curl call starts with -q" $?
grep -qF 'repository:open-platform-model/opmodel.dev/templates/minimal:pull' "$CURL_LOG"
check "token scope is cue's GHCR path for the module" $?
grep -qF -- '--connect-timeout 10 --max-time 60' "$CURL_LOG"; check "curl has timeouts" $?

mk 1.0.2; run "declared published, newer published: above the highest" 0 1.0.4 "1.0.2 -> 1.0.4" "$mv_" PAGE1="v1.0.2 v1.0.3"
mk 1.0.3; run "other majors and prereleases ignored" 0 1.0.4 "1.0.3 -> 1.0.4" "$mv_" PAGE1="v1.0.3 v1.0.10-rc.1 v2.0.0 v10.0.0"
mk 1.0.9; run "numeric order: 1.0.10 above 1.0.9" 0 1.0.11 "1.0.9 -> 1.0.11" "$mv_" PAGE1="v1.0.9 v1.0.10"
mk 1.0.3; run "pagination: declared on page 2" 0 1.0.4 "1.0.3 -> 1.0.4" "$mv_" PAGE1="v1.0.1" PAGE2="v1.0.2 v1.0.3"
mk 1.0.4; run "declared pending above the highest: no bump" 0 1.0.4 "not published yet" "$mv_" PAGE1="v1.0.2 v1.0.3"
check "pending: opm not called" "$(($(wc -c <"$OPM_LOG") == 0 ? 0 : 1))"
mk 1.0.1; run "declared pending below the highest: fail" 1 1.0.1 "not above the published v1.0.3" "$mv_" PAGE1="v1.0.3"
mk 1.0.0; run "new template (token 403): no bump, visibility note" 0 1.0.0 "make the package public" "$mv_" TOKEN_CODE=403
mk 1.0.0; run "tags list 404 on page 1: no versions" 0 1.0.0 "make the package public" "$mv_" TAGS_CODE=404
mk 1.0.3; run "token 500: fail, no bump" 1 1.0.3 "token request answered 500" "$mv_" TOKEN_CODE=500
mk 1.0.3; run "tags 429: fail, no bump" 1 1.0.3 "tags list answered 429" "$mv_" TAGS_CODE=429
mk 1.0.3; run "network down: fail, no bump" 1 1.0.3 "token request answered 000" "$mv_" TOKEN_CODE=000
mk 1.0.3-rc.1; run "prerelease version: fail" 1 1.0.3-rc.1 "not a stable X.Y.Z" "$mv_" PAGE1="v1.0.3"
mk 1.0.3; run "tidy fails: fail, no bump" 1 1.0.3 "cue mod tidy failed" "$mv_" FAKE_TIDY_RC=1 PAGE1="v1.0.3"
mk 1.0.3
: >"$OPM_LOG"
(cd "$ws" && env PATH="$root/nobin:/usr/bin:/bin" "$mv_" PAGE1="v1.0.3" CURL_LOG="$CURL_LOG" "$ts" >"$root/out" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -qF 'opm is required' "$root/out" && [ "$(ver)" = 1.0.3 ]
check "opm missing when a bump is due: fail" $?
mkdir -p "$root/empty"
(cd "$root/empty" && env PATH="$root/bin:$PATH0" "$ts" >"$root/out" 2>&1); check "no cli checkout: nothing to do" $?

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
