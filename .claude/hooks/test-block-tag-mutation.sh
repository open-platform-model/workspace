#!/usr/bin/env bash
# Table test for block-tag-mutation.sh. Run from anywhere:
#   .claude/hooks/test-block-tag-mutation.sh
# Each case feeds the hook a PreToolUse JSON payload and checks the exit code
# (2 = blocked, 0 = allowed). Exits non-zero when any case fails.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/block-tag-mutation.sh"

# Scratch repo holding a local tag with a non-version name, to exercise the
# "bare name that is a local tag" detection.
repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$repo" tag snapshot-tag

pass=0
fail=0

run() {
  local want="$1" cmd="$2" got
  jq -nc --arg c "$cmd" --arg d "$repo" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | "$hook" >/dev/null 2>&1
  case $? in
    2) got=block ;;
    0) got=allow ;;
    *) got=error ;;
  esac
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL want=%s got=%s: %s\n' "$want" "$got" "$cmd"
  fi
}

# ------------------------------------------------------------- blocked: git tag
run block 'git tag -d v1.2.3'
run block 'git tag --delete v1.2.3'
run block 'git tag --del v1.2.3'
run block 'git tag -f v1.2.3 HEAD'
run block 'git tag --force v1.2.3'
run block 'git tag -fa v1.2.3 -m "moved"'
run block 'git tag -am "msg" -f v1.2.3'
run block 'git -C core tag -d v2.0.0'
run block 'git -c user.name=x tag -d v2.0.0'
run block 'cd core && git tag -d v2.0.0'
run block 'git status; git tag -d v2.0.0'
run block 'false || git tag -d v2.0.0'
run block 'git tag -l "v*" | xargs git tag -d'
run block 'git tag -l | xargs -n1 git tag -d'
run block 'GIT_TRACE=1 git tag -d v1.0.0'
run block 'env GIT_TRACE=1 git tag -d v1.0.0'
run block 'for t in $(git tag); do git tag -d $t; done'
run block 'bash -c "git tag -d v1.0.0"'
run block "sh -lc 'git push origin :refs/tags/v1.0.0'"
run block 'eval "git tag -d v1.0.0"'
run block 'echo "$(git tag -d v1.0.0)"'
run block $'bash <<\'EOF\'\ngit tag -d v1.0.0\nEOF'
run block $'git status \\\n  && git tag -d v1.0.0'

# ------------------------------------------------------------- blocked: update-ref
run block 'git update-ref refs/tags/v1.0.0 HEAD'
run block 'git update-ref -d refs/tags/v1.0.0'

# ------------------------------------------------------------- blocked: git push
run block 'git push origin :refs/tags/v1.0.0'
run block 'git push origin :v1.0.0'
run block 'git push --delete origin v1.0.0'
run block 'git push origin --delete refs/tags/opm-v1.2.0'
run block 'git push -d origin catalogs/opm/v4.0.1'
run block 'git push origin +refs/tags/v1.0.0'
run block 'git push origin +HEAD:refs/tags/v1.0.0'
run block 'git push --force origin v1.0.0'
run block 'git push -f origin refs/tags/v1.0.0'
run block 'git push --force-with-lease origin refs/tags/v2.0.0-beta.1'
run block 'git push --force --tags origin'
run block 'git push origin --tags -f'
run block 'git push --force --follow-tags origin main'
run block 'git push --mirror origin'
run block 'git push --prune origin refs/heads/*:refs/heads/*'
run block 'git push origin +refs/tags/*:refs/tags/*'
run block 'git push -f origin tag v1.0.0'
run block 'git push --force origin snapshot-tag'
run block 'git push origin :snapshot-tag'
run block 'git push --force-w origin v1.0.0'

# ------------------------------------------------------------- blocked: gh / curl
run block 'gh release delete v1.0.0 --yes'
run block 'gh release delete-asset v1.0.0 opm_linux_amd64.tar.gz'
run block 'gh release edit v1.0.0 --tag v1.0.1'
run block 'gh release edit v1.0.0 --target=abc123'
run block 'gh release upload v1.0.0 dist/opm.tar.gz --clobber'
run block 'gh -R open-platform-model/cli release delete v1.0.0'
run block 'gh api -X DELETE repos/open-platform-model/core/git/refs/tags/v2.0.0'
run block 'gh api --method PATCH repos/open-platform-model/core/git/refs/tags/v2.0.0 -f sha=abc -F force=true'
run block 'gh api -XPATCH repos/open-platform-model/cli/releases/123 -f tag_name=v9'
run block 'gh api repos/open-platform-model/cli/releases -f tag_name=v9.9.9'
run block 'gh api --method DELETE repos/open-platform-model/cli/releases/assets/9'
run block 'gh api -X PUT orgs/open-platform-model/rulesets/1 --input r.json'
run block 'gh api -X DELETE repos/open-platform-model/core/rulesets/42'
run block 'gh api --method PUT orgs/open-platform-model/settings/immutable-releases -f enforced_repositories=none'
run block 'gh api graphql -f query="mutation { deleteRef(input:{refId:\"x\"}) { clientMutationId } }"'
run block 'gh api graphql -F query=@m.graphql -f q2="updateRefs(input:{})"'
run block 'gh auth refresh -h github.com -s admin:org'
run block 'gh auth login --scopes repo,delete_repo'
run block 'gh repo delete open-platform-model/sandbox --yes'
run block 'curl -X DELETE -H "Authorization: token x" https://api.github.com/repos/o/r/git/refs/tags/v1.0.0'

# ------------------------------------------------------------- allowed
run allow 'git push origin main'
run allow 'git push --force-with-lease origin chore/tags-immutable'
run allow 'git push -u origin feat/x'
run allow 'git push origin --delete feat/old-branch'
run allow 'git push origin v1.0.0'
run allow 'git push origin refs/tags/new-tag'
run allow 'git push origin HEAD:refs/tags/v3.0.0'
run allow 'git push origin tag v1.0.0'
run allow 'git push --tags origin'
run allow 'git push --follow-tags origin main'
run allow 'git push origin snapshot-tag'
run allow 'git tag v1'
run allow 'git tag -a v1.0.0 -m "release -d -f"'
run allow 'git tag -l "v*"'
run allow 'git tag --list --sort=-v:refname'
run allow 'git tag --contains HEAD'
run allow 'git -C core tag -n5'
run allow 'git fetch --tags origin'
run allow 'git ls-remote origin refs/tags/v1.0.0'
run allow 'git update-ref refs/heads/scratch HEAD'
run allow 'git commit -m "docs: never run git tag -d v1.0.0 or git push --delete"'
run allow $'git commit -F - <<\'EOF\'\nchore: explain why git tag -d v1.0.0 is forbidden\nEOF'
run allow 'gh release view v1.0.0'
run allow 'gh release list --limit 5'
run allow 'gh release view v1.0.0 --json isDraft'
run allow 'gh release create v1.0.1 --draft --notes x'
run allow 'gh release edit v1.0.0 --draft=false'
run allow 'gh release edit v1.0.0 --notes-file notes.md'
run allow 'gh release upload v1.0.0 dist/opm.tar.gz'
run allow 'gh api repos/open-platform-model/core/git/refs/tags/v2.0.0'
run allow 'gh api repos/open-platform-model/core/releases --paginate --jq ".[].tag_name"'
run allow 'gh api -X GET repos/open-platform-model/cli/releases -f per_page=100'
run allow 'gh api orgs/open-platform-model/rulesets'
run allow 'gh api repos/open-platform-model/core/rulesets/42 --jq .bypass_actors'
run allow 'gh api graphql -f query="query { repository(owner:\"o\", name:\"r\") { refs(refPrefix:\"refs/tags/\", first:5) { nodes { name } } } }"'
run allow 'gh api -X POST repos/o/r/issues -f title=x'
run allow 'gh auth status'
run allow 'gh auth refresh -s read:packages'
run allow 'gh pr create --title "chore: x" --body "never run gh release delete"'
run allow 'curl -s https://api.github.com/repos/o/r/git/refs/tags/v1.0.0'
run allow 'echo "git tag -d v1.0.0"'
run allow 'grep -rn "git push --mirror" .'
run allow 'ls -la && git status 2>&1 | head'

total=$((pass + fail))
echo "block-tag-mutation: $pass/$total passed, $fail failed"
[ "$fail" -eq 0 ]
