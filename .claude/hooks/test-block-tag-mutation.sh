#!/usr/bin/env bash
# Table test for block-tag-mutation.sh. Run from anywhere:
#   .claude/hooks/test-block-tag-mutation.sh
# Each case feeds the hook a PreToolUse JSON payload and checks the exit code
# (2 = blocked, 0 = allowed). Exits non-zero when any case fails.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/block-tag-mutation.sh"

# Scratch workspace: one clone per scope case, told apart only by its remote URL.
#   ws/core         origin https  open-platform-model/core      (in scope, default cwd)
#   ws/cli          origin ssh    open-platform-model/cli       (in scope)
#   ws/modules      origin        open-platform-model/modules   (excluded)
#   ws/opm-modules  origin        emil-jacero/opm-modules       (personal, excluded)
#   ws/fork         origin fork, upstream open-platform-model/library
#   ws/plain        no remote                                    (unknown, passes)
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
ws="$root/ws"
mkrepo() {
  local dir="$ws/$1"
  shift
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$dir" tag snapshot-tag
  while [ $# -gt 0 ]; do
    git -C "$dir" remote add "$1" "$2"
    shift 2
  done
}
mkrepo core origin https://github.com/open-platform-model/core.git
mkrepo cli origin git@github.com:open-platform-model/cli.git
mkrepo modules origin https://github.com/open-platform-model/modules.git
mkrepo opm-modules origin https://github.com/emil-jacero/opm-modules.git
mkrepo fork origin https://github.com/emil-jacero/library.git upstream https://github.com/open-platform-model/library
mkrepo plain
git -C "$ws/core" branch chore/bump-core-v2.0.0
printf 'mutation { deleteRef(input:{refId:"x"}) { clientMutationId } }\n' >"$ws/core/deleteref.graphql"

pass=0
fail=0
cwd="$ws/core"

run() {
  local want="$1" cmd="$2" got
  jq -nc --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
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
    printf 'FAIL want=%s got=%s cwd=%s: %s\n' "$want" "$got" "${cwd#"$ws"/}" "$cmd"
  fi
}

# run_in DIR WANT CMD: one case with the session cwd at ws/DIR (or ws for "").
run_in() {
  local saved="$cwd"
  cwd="$ws${1:+/$1}"
  run "$2" "$3"
  cwd="$saved"
}

# ------------------------------------------------------------- blocked: git tag
run block 'git tag -d v1.2.3'
run block 'git tag --delete v1.2.3'
run block 'git tag --del v1.2.3'
run block 'git tag -f v1.2.3 HEAD'
run block 'git tag --force v1.2.3'
run block 'git tag -fa v1.2.3 -m "moved"'
run block 'git tag -am "msg" -f v1.2.3'
run_in '' block 'git -C core tag -d v2.0.0'
run block 'git -c user.name=x tag -d v2.0.0'
run_in '' block 'cd core && git tag -d v2.0.0'
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
run block 'gh repo delete open-platform-model/release-flow-sandbox --yes'
run block 'curl -X DELETE -H "Authorization: token x" https://api.github.com/repos/open-platform-model/core/git/refs/tags/v1.0.0'

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
run_in '' allow 'git -C core tag -n5'
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

# ------------------------------------------------------------- scope: in-scope targets
run_in cli block 'git tag -d v1.0.0'
run_in cli block 'git push origin :refs/tags/v1.0.0'
run_in fork block 'git tag -d v1.0.0'
run_in fork block 'git push upstream :refs/tags/v1.0.0'
run_in fork block 'git push upstream --force v1.0.0'
run_in plain block 'git push https://github.com/open-platform-model/cli.git :refs/tags/v1.0.0'
run_in plain block 'git -C ../core tag -d v1.0.0'
run_in plain block 'gh release delete v1.0.0 -R open-platform-model/opm-operator --yes'
run_in plain block 'gh release delete v1.0.0 --repo=open-platform-model/catalog_opm --yes'
run_in plain block 'GH_REPO=open-platform-model/library gh release delete v1.0.0 --yes'
run_in plain block 'gh api -X DELETE repos/open-platform-model/release-flow-sandbox/git/refs/tags/v0.1.0'
run_in plain block 'gh api -X PUT orgs/open-platform-model/rulesets/1 --input r.json'
run_in modules block 'gh auth refresh -s admin:org'
run block 'gh api -X DELETE "repos/{owner}/{repo}/git/refs/tags/v1.0.0"'

# ------------------------------------------------------------- scope: excluded targets pass
run_in modules allow 'git tag -d sonarr/v1.0.1'
run_in modules allow 'git push origin :refs/tags/modules/sonarr/v1.2.3'
run_in modules allow 'git push --force origin v1.0.0'
run_in modules allow 'gh release delete v1.0.0 --yes'
run_in modules allow 'git push origin --delete release/v1.0'
run_in opm-modules allow 'git tag -d v1.0.0'
run_in opm-modules allow 'git push --mirror origin'
run_in plain allow 'git tag -d v1.0.0'
run_in plain allow 'git push origin :refs/tags/v1.0.0'
run_in plain allow 'gh api -X DELETE "repos/{owner}/{repo}/git/refs/tags/v1.0.0"'
run_in '' allow 'git -C modules tag -d sonarr/v1.0.1'
run_in '' allow 'git -C opm-modules push origin :refs/tags/modules/sonarr/v1.2.3'
run_in '' allow 'cd modules && git tag -d v1.0.0'
run_in fork allow 'git push origin --force v1.0.0'
run allow 'git push https://github.com/emil-jacero/opm-modules.git :refs/tags/v1.0.0'
run allow 'gh release delete v1.0.0 -R emil-jacero/opm-modules --yes'
run allow 'gh release delete v1.0.0 -R open-platform-model/modules --yes'
run allow 'gh api -X DELETE repos/emil-jacero/opm-modules/git/refs/tags/modules/sonarr/v1.2.3'
run allow 'gh api -X DELETE repos/open-platform-model/modules/releases/123'
run allow 'gh api -X PUT orgs/emil-jacero/rulesets/1 --input r.json'
run allow 'curl -X DELETE https://api.github.com/repos/o/r/git/refs/tags/v1.0.0'

# ------------------------------------------------------------- release branches
run block 'git push origin --delete release/v1.0'
run block 'git push -f origin release/v1.0'
run block 'git push origin HEAD:release/v1.0'
run block 'git push origin :refs/heads/release/opm-v4.4'
run block 'gh api -X DELETE repos/open-platform-model/core/git/refs/heads/release/v2.0'
run allow 'git push -u origin fix/backport-schema-default'
run allow 'gh pr create --base release/v1.0 --title "fix: backport x" --body y'

# ------------------------------------------------------------- review fixes: indirection and encoding
run block 'TAG=v1.2.3; git push --delete origin "$TAG"'
run block 'git push origin ":$TAG"'
run block 'git ls-remote --tags origin | cut -f2 | xargs -n1 git push origin --delete'
run block 'git tag -l | xargs -I{} git push origin :{}'
run block 'git push origin --delete $(git tag -l "v*")'
run block "echo 'git tag -d v1.2.3' | bash"
run block "printf 'git push origin :refs/tags/v1.2.3\\n' | sh"
run block $'cat <<\'EOF\' | /bin/bash\ngit tag -d v1.2.3\nEOF'
run block "bash <<< 'git tag -d v1.2.3'"
run block $'echo "<<X"\ngit tag -d v1.2.3'
run block "git -c alias.zap='tag -d' zap v1.2.3"
run block "git -c alias.p='push --force' p origin v1.2.3"
run block 'git -c remote.origin.mirror=true push origin'
run block 'gh api -X DELETE repos/open-platform-model/core/git/refs/%74ags/v1.2.3'
run block 'gh api -X DELETE repos/open-platform-model/core/%72eleases/123'
run block 'curl -sSfX DELETE https://api.github.com/repos/open-platform-model/core/git/refs/tags/v1.2.3'
run block 'wget --method=DELETE https://api.github.com/repos/open-platform-model/cli/releases/1'
run block "gh api graphql -f query='mutation { deleteRepositoryRuleset(input:{repositoryRulesetId:\"x\"}) { clientMutationId } }'"
run block 'gh api graphql -F query=@deleteref.graphql'
run block 'gh api graphql -F query=@missing.graphql'
run block 'gh api graphql -f query="$Q"'
run block 'gh release edit v1.0.0 --draft'
run block 'gh release edit v1.0.0 --draft=true'

# ------------------------------------------------------------- review fixes: false positives
run allow "grep -n '\`git tag -f\` / \`-d\`' AGENTS.md"
run allow "git commit -m 'docs: forbid \`git tag -d v1.2.3\` in agent shells'"
run allow "gh pr comment 3 --body 'The hook now blocks \`gh release delete v1.2.3\`.'"
run allow "git commit -m 'explain: never run \$(git tag -d v1.2.3)'"
run allow 'git push --force-with-lease origin chore/bump-core-v2.0.0'
run allow 'gh api -X POST repos/open-platform-model/cli/releases/generate-notes -f tag_name=v1.0.1'
run allow "gh api graphql -f query='query(\$o: String!) { repository(owner: \$o, name: \"cli\") { id } }' -f o=x"
run allow 'git push --force-with-lease origin "$BRANCH"'
run_in plain allow 'gh api graphql -f query="$Q"'

total=$((pass + fail))
echo "block-tag-mutation: $pass/$total passed, $fail failed"
[ "$fail" -eq 0 ]
