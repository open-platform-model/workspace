#!/usr/bin/env bash
# Offline table test for latest-tag.sh and platform-pins.sh. Run from anywhere:
#   .tasks/deps/test-latest-tag.sh
# git and curl are PATH shims: git prints a fake tag list, curl answers a fake
# HTTP status per URL suffix and logs its arguments. No network, no registry.
# Exits non-zero when any case fails.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lt="$here/latest-tag.sh"
pp="$here/platform-pins.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin"

# git ls-remote shim: FAKE_TAGS lists tag names; the last argument is the
# refs/tags/<prefix>* pattern, applied as a glob like real git does.
cat >"$root/bin/git" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_GIT_FAIL:-0}" = 1 ] && { echo "fatal: unable to access" >&2; exit 128; }
pat="${*: -1}"
while read -r t; do
  [ -n "$t" ] || continue
  # shellcheck disable=SC2053
  [[ "refs/tags/$t" == $pat ]] && printf '0000000\trefs/tags/%s\n' "$t"
done <"$FAKE_TAGS"
exit 0
EOF
# curl shim: FAKE_CODES lines are "<url suffix> <status>", first match wins,
# default 200. Status 000 mimics a network failure (curl exit 7).
cat >"$root/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
url="${*: -1}"; code=200
while read -r suffix c; do
  [ -n "$suffix" ] || continue
  [[ "$url" == *"$suffix" ]] && { code="$c"; break; }
done <"$FAKE_CODES"
printf '%s' "$code"
[ "$code" = 000 ] && exit 7
exit 0
EOF
chmod +x "$root/bin/git" "$root/bin/curl"
export PATH="$root/bin:$PATH" FAKE_TAGS="$root/tags" FAKE_CODES="$root/codes" CURL_LOG="$root/curl.log"

pass=0
fail=0
check() { # $1 name, $2 0|1 condition result
  if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; fi
}
tags() { printf '%s\n' "$@" >"$FAKE_TAGS"; }
codes() { printf '%s\n' "$@" >"$FAKE_CODES"; }
assets=opm-linux-amd64.tar.gz,checksums.txt

# lt_case <name> <want rc> <want stdout> <stderr substring or ""> [latest-tag args...]
lt_case() {
  local name="$1" wrc="$2" wout="$3" werr="$4" out rc
  shift 4
  : >"$CURL_LOG"
  out=$("$lt" "$@" 2>"$root/err"); rc=$?
  local ok=1 err
  err=$(tr '\n' ' ' <"$root/err")
  [ "$rc" = "$wrc" ] && [ "$out" = "$wout" ] && { [ -z "$werr" ] || grep -qF -- "$werr" "$root/err"; } && ok=0
  check "$name (rc=$rc out='$out' err=$err)" "$ok"
}

base=(v1.0.0-alpha.9 v1.0.0-alpha.10 v1.0.0-beta.1 v1.0.0-beta.2 v1.0.0-beta.3-0.dev.20260901 v1.0.0)

tags "${base[@]}"; codes
lt_case "newest, both assets present" 0 1.0.0 "" cli v "$assets"
lt_case "every probe passes -q first (no ~/.curlrc)" 0 1.0.0 "" cli v "$assets"
! grep -qv '^-q ' "$CURL_LOG"; check "curl -q is the first argument" $?
check "both assets probed for the winner" "$(($(wc -l <"$CURL_LOG") == 2 ? 0 : 1))"

codes "v1.0.0/checksums.txt 404"
lt_case "checksums.txt missing: skip to previous" 0 1.0.0-beta.2 "v1.0.0: checksums.txt not downloadable" cli v "$assets"
codes "v1.0.0/opm-linux-amd64.tar.gz 404"
lt_case "tarball missing: skip to previous" 0 1.0.0-beta.2 "v1.0.0: opm-linux-amd64.tar.gz not downloadable" cli v "$assets"
! grep -q 'beta.3-0.dev' "$CURL_LOG"; check "-0.dev. tag never probed" $?
codes "v1.0.0/opm-linux-amd64.tar.gz 404" "v1.0.0-beta.2/checksums.txt 404" "v1.0.0-beta.1/checksums.txt 404"
lt_case "prerelease order: alpha.10 above alpha.9" 0 1.0.0-alpha.10 "" cli v "$assets"

codes "v1.0.0/opm-linux-amd64.tar.gz 000"
lt_case "network failure aborts, no fallback" 1 "" "answered '000'; refusing to guess" cli v "$assets"
codes "v1.0.0/checksums.txt 503"
lt_case "5xx aborts, no fallback" 1 "" "answered '503'" cli v "$assets"
codes "v1.0.0/opm-linux-amd64.tar.gz 429"
lt_case "429 aborts, no fallback" 1 "" "answered '429'" cli v "$assets"

codes
FAKE_GIT_FAIL=1 lt_case "explicit version: verified, git not consulted" 0 1.0.0-beta.1 "" cli v "$assets" v1.0.0-beta.1
codes "v1.0.0-alpha.21/opm-linux-amd64.tar.gz 404"
lt_case "explicit version missing an asset is refused" 1 "" "v1.0.0-alpha.21 is not a consumable cli release" cli v "$assets" v1.0.0-alpha.21

tags opm-v4.4.4 k8s-v1.0.0-beta.1; codes
lt_case "no matching tags" 1 "" "no v* release tags in cli" cli v "$assets"
FAKE_GIT_FAIL=1 lt_case "git failure" 1 "" "cannot list v* tags of cli" cli v "$assets"
lt_case "usage: asset list required" 1 "" "usage:" cli v
tags "${base[@]}"; codes
lt_case "empty asset list refused" 1 "" "<asset> list is required" cli v ""
lt_case "empty asset name refused" 1 "" "<asset> list is required" cli v "a,,b"
lt_case "curl gets connect and total timeouts" 0 1.0.0 "" cli v "$assets"
grep -q -- '--connect-timeout 10 --max-time 60' "$CURL_LOG"; check "curl runs with --connect-timeout 10 --max-time 60" $?

tags v0.1.0 v0.2.0 v0.3.0 v0.4.0 v0.5.0 v0.6.0 v0.7.0 v0.8.0 v0.9.0 v0.10.0 v0.11.0; codes "checksums.txt 404"
lt_case "bounded walk: 11 broken releases" 1 "" "none of the newest 10 v* tags" cli v checksums.txt
check "bounded walk probes exactly 10 candidates" "$(($(wc -l <"$CURL_LOG") == 10 ? 0 : 1))"

# platform-pins.sh mirrors cli/hack/platform/cue.mod/module.cue, offline.
mkpp() { # $1 dir, $2 opm dep key, $3 opm v, $4 k8s v
  mkdir -p "$1/cli/hack/platform/cue.mod" "$1/opm-operator/config/samples"
  printf 'deps: {\n\t"%s": {\n\t\tv: "%s"\n\t}\n\t"opmodel.dev/catalogs/k8s@v1": {\n\t\tv: "%s"\n\t}\n}\n' \
    "$2" "$3" "$4" >"$1/cli/hack/platform/cue.mod/module.cue"
  local y='    opmodel.dev/catalogs/opm@v4:\n      version: "4.0.0"\n    opmodel.dev/catalogs/k8s@v1:\n      # comment line\n      version: "1.0.0-alpha.1"\n'
  printf 'spec:\n  registry:\n%b' "$y" >"$1/cli/hack/kind-platform.yaml"
  printf 'spec:\n  registry:\n%b' "$y" >"$1/opm-operator/config/samples/opmodel.dev_v1alpha1_platform.yaml"
}
: >"$CURL_LOG"; tags
mkpp "$root/pp1" opmodel.dev/catalogs/opm@v4 v4.6.0-alpha.1 v1.0.0
(cd "$root/pp1" && FAKE_GIT_FAIL=1 "$pp" >/dev/null 2>&1); check "platform-pins succeeds offline" $?
for f in cli/hack/kind-platform.yaml opm-operator/config/samples/opmodel.dev_v1alpha1_platform.yaml; do
  grep -qF 'version: "4.6.0-alpha.1"' "$root/pp1/$f" && grep -qF 'version: "1.0.0"' "$root/pp1/$f"
  check "platform-pins mirrors cue.mod into $f" $?
done
check "platform-pins makes no HTTP call" "$(($(wc -c <"$CURL_LOG") == 0 ? 0 : 1))"
mkpp "$root/pp2" opmodel.dev/catalogs/opm@v5 v5.0.0 v1.0.0
cp "$root/pp2/cli/hack/kind-platform.yaml" "$root/before.yaml"
(cd "$root/pp2" && "$pp" >/dev/null 2>"$root/err"); rc=$?
[ "$rc" != 0 ] && grep -qF 'does not pin opmodel.dev/catalogs/opm@v4' "$root/err" \
  && cmp -s "$root/before.yaml" "$root/pp2/cli/hack/kind-platform.yaml"
check "major moved in cue.mod: refuse, YAML untouched" $?
mkpp "$root/pp4" opmodel.dev/catalogs/opm@v4 v4.6.0 v1.0.0
sed -i 's#catalogs/k8s@v1:#catalogs/k8s@v2:#' "$root/pp4/cli/hack/kind-platform.yaml"
(cd "$root/pp4" && "$pp" >/dev/null 2>"$root/err"); rc=$?
[ "$rc" != 0 ] && grep -qF '1 key(s) not found' "$root/err" \
  && grep -qF 'version: "4.6.0"' "$root/pp4/opm-operator/config/samples/opmodel.dev_v1alpha1_platform.yaml"
check "YAML missing a key: fails, other keys still synced" $?
mkdir -p "$root/pp3"
(cd "$root/pp3" && "$pp" >/dev/null 2>"$root/err"); rc=$?
[ "$rc" != 0 ] && grep -qF 'not found (is cli checked out?)' "$root/err"
check "mirror cue.mod absent: refuse" $?

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
