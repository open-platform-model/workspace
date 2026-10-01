#!/usr/bin/env bash
# PreToolUse hook (Bash): blocks commands that move, delete or re-create a release tag, mutate a
# published release, or weaken the org controls that keep tags immutable.
#
# Rule: "Release Tags Are Immutable" in the workspace AGENTS.md. This hook is defence in depth;
# the org tag ruleset and immutable releases are the real control.
#
# Wired from the tracked .claude/settings.json as a PreToolUse hook on Bash.
# Input: the hook JSON on stdin (tool_input.command, cwd).
# Output: exit 2 with the reason on stderr to block; exit 0 to allow.
#
# The command is tokenized (shlex), not substring-grepped: chained commands (&& || ; | &),
# subshells, $(...), bash -c / eval strings, env-var prefixes and wrappers (env, sudo, xargs,
# timeout), git global options (-C dir, -c k=v) and quoted arguments are all handled.
# Heredoc bodies are treated as data (commit messages, PR bodies) unless fed to a shell.
#
# Blocked:
#   git tag -d/--delete/-f/--force                (creating a tag is allowed)
#   git update-ref on refs/tags/...
#   git push: --mirror, --prune, a delete (:tag, --delete/-d tag), or a force (+tag, --force/-f,
#             --force-with-lease) together with a tag ref or --tags/--follow-tags
#             (pushing a NEW tag is allowed). A ref counts as a tag when it starts with
#             refs/tags/, looks like a release version (v1.2.3, opm-v1.2.3, x/y/v1.2.3), or
#             exists as a local tag in the target repo.
#   gh release delete | delete-asset, gh release edit --tag/--target, gh release upload --clobber
#   gh api / curl writes (non-GET) on git/refs/tags, releases, rulesets, immutable-releases;
#             GraphQL deleteRef/updateRef(s)
#   gh auth login/refresh requesting admin:org, admin:enterprise or delete_repo; gh repo delete
#
# Requires python3; without it the hook allows the command (fail open) and says so on stderr.
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "block-tag-mutation: python3 not found, tag-mutation check skipped" >&2
  exit 0
fi

script=$(cat <<'PY'
import json, os, re, shlex, subprocess, sys

FOOTER = (
    "Release tags are immutable: no tag under refs/tags/ is ever moved, deleted or re-created, "
    "by anyone. Fix a wrong or broken release by releasing the next version (Go: retract in the "
    "new version; CUE/OCI: publish the next version). Release mutations belong to the release "
    "workflow, not to an agent shell. See 'Release Tags Are Immutable' in the workspace AGENTS.md. "
    "If this is a false positive, ask the user to run the command themselves."
)

PUNCT = ";&|()<>\n"
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
SIMPLE_WRAPPERS = {"sudo", "command", "exec", "nohup", "time", "builtin", "then", "do", "else",
                   "elif", "if", "while", "until", "!", "{", "}", "stdbuf", "nice", "unbuffer"}
VERSION_TAG = re.compile(r"^(?:[A-Za-z0-9._-]+[/-])*v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?$")
HEREDOC = re.compile(r"(?<!<)<<(?!<)(-?)\s*(?:'([^']+)'|\"([^\"]+)\"|\\?([A-Za-z_][A-Za-z0-9_]*))")
SHELL_LINE = re.compile(r"(^|[\s;&|(])(?:ba|z|da|k)?sh(\s|$)")
MAX_DEPTH = 4


class Blocked(Exception):
    pass


def block(msg):
    raise Blocked(msg)


# ---------------------------------------------------------------- tokenizing

def split_heredocs(s):
    """Return (script without heredoc bodies, [(introducing line, body)])."""
    lines = s.split("\n")
    out, bodies, i = [], [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        for m in HEREDOC.finditer(line):
            dash = m.group(1) == "-"
            delim = m.group(2) or m.group(3) or m.group(4)
            body = []
            while i < len(lines):
                cur = lines[i]
                i += 1
                if (cur.lstrip("\t") if dash else cur) == delim:
                    break
                body.append(cur)
            bodies.append((line, "\n".join(body)))
    return "\n".join(out), bodies


def tokenize(s):
    lex = shlex.shlex(s, posix=True, punctuation_chars=PUNCT)
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def segments(s):
    s = s.replace("\\\n", " ")
    try:
        toks = tokenize(s)
    except ValueError:
        segs = []
        for line in s.splitlines():
            for part in re.split(r"&&|\|\||[;|&()]", line):
                try:
                    words = shlex.split(part)
                except ValueError:
                    words = part.split()
                if words:
                    segs.append(words)
        return segs
    segs, cur, i = [], [], 0
    while i < len(toks):
        t = toks[i]
        if t and all(c in PUNCT for c in t):
            if "<" in t or ">" in t:
                if cur and cur[-1].isdigit():
                    cur.pop()  # fd number of a redirect such as 2>&1
                i += 2  # drop the redirect target
                continue
            if cur:
                segs.append(cur)
                cur = []
            i += 1
            continue
        cur.append(t)
        i += 1
    if cur:
        segs.append(cur)
    return segs


def check_script(s, cwd, depth):
    if depth > MAX_DEPTH:
        return
    stripped, bodies = split_heredocs(s)
    for intro, body in bodies:
        if SHELL_LINE.search(intro):
            check_script(body, cwd, depth + 1)
    for seg in segments(stripped):
        # command substitutions kept inside a single quoted word
        for t in seg:
            if "$(" in t:
                check_script(t[t.index("$(") + 2:], cwd, depth + 1)
            if t.count("`") >= 2:
                for inner in t.split("`")[1::2]:
                    check_script(inner, cwd, depth + 1)
        check_segment(seg, cwd, depth)


# ---------------------------------------------------------------- dispatch

def strip_prefix(seg):
    i = 0
    while i < len(seg):
        t = seg[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            i += 1
            continue
        base = os.path.basename(t.lstrip("`$("))
        if base == "env":
            i += 1
            while i < len(seg) and (seg[i].startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", seg[i])):
                i += 2 if seg[i] in ("-u", "--unset", "-C", "--chdir") else 1
            continue
        if base == "xargs":
            i += 1
            while i < len(seg) and seg[i].startswith("-"):
                i += 2 if seg[i] in ("-I", "-n", "-L", "-P", "-d", "-E", "-s", "-a") else 1
            continue
        if base == "timeout":
            i += 1
            while i < len(seg) and seg[i].startswith("-"):
                i += 2 if seg[i] in ("-s", "-k", "--signal", "--kill-after") else 1
            i += 1  # duration
            continue
        if base in SIMPLE_WRAPPERS:
            i += 1
            while i < len(seg) and seg[i].startswith("-"):
                i += 2 if seg[i] in ("-u", "-g", "-n") else 1
            continue
        break
    return seg[i:]


def check_segment(seg, cwd, depth):
    seg = strip_prefix(seg)
    if not seg:
        return
    base = os.path.basename(seg[0].lstrip("`$("))
    args = seg[1:]
    if base in SHELLS:
        for j, a in enumerate(args):
            if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a) and j + 1 < len(args):
                check_script(args[j + 1], cwd, depth + 1)
                break
    elif base == "eval":
        check_script(" ".join(args), cwd, depth + 1)
    elif base == "git":
        check_git(args, cwd, seg)
    elif base == "gh":
        check_gh(args)
    elif base == "curl":
        check_curl(args)


# ---------------------------------------------------------------- git

def resolve_long(name, options):
    if name in options:
        return name
    hits = [o for o in options if o.startswith(name)]
    return hits[0] if len(hits) == 1 else name


def local_tag_exists(name, gitdir):
    if not name or name.startswith("refs/") or any(c in name for c in "*?[~^:"):
        return False
    try:
        r = subprocess.run(["git", "-C", gitdir, "rev-parse", "--verify", "--quiet", "refs/tags/" + name],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
        return r.returncode == 0
    except Exception:
        return False


def is_tag(ref, gitdir):
    if not ref:
        return False
    if ref.startswith("refs/tags/"):
        return True
    if ref.startswith("refs/") or ref == "HEAD":
        return False
    return bool(VERSION_TAG.match(ref)) or local_tag_exists(ref, gitdir)


def check_git(args, cwd, seg):
    gitdir, i = cwd, 0
    while i < len(args):
        a = args[i]
        if a == "-C":
            if i + 1 < len(args):
                gitdir = os.path.join(gitdir, os.path.expanduser(args[i + 1]))
            i += 2
            continue
        if a in ("-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"):
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        break
    if i >= len(args):
        return
    sub, rest = args[i], args[i + 1:]
    if sub == "tag":
        check_git_tag(rest)
    elif sub == "update-ref":
        if any("refs/tags" in a for a in rest):
            block("git update-ref on refs/tags/ rewrites or deletes a tag.")
        if "--stdin" in rest and any("refs/tags" in t for t in seg):
            block("git update-ref --stdin with refs/tags/ rewrites or deletes a tag.")
    elif sub == "push":
        check_git_push(rest, gitdir)


GIT_TAG_LONG = ["annotate", "sign", "no-sign", "local-user", "force", "delete", "verify", "list",
                "sort", "contains", "no-contains", "merged", "no-merged", "points-at", "message",
                "file", "edit", "no-edit", "cleanup", "create-reflog", "column", "no-column",
                "format", "color", "ignore-case", "omit-empty", "trailer"]
GIT_TAG_LONG_ARG = {"local-user", "sort", "contains", "no-contains", "merged", "no-merged",
                    "points-at", "message", "file", "cleanup", "format", "trailer"}


def check_git_tag(rest):
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--":
            break
        if a.startswith("--"):
            name = resolve_long(a[2:].split("=", 1)[0], GIT_TAG_LONG)
            if name == "delete":
                block("git tag --delete removes a release tag.")
            if name == "force":
                block("git tag --force re-points an existing tag. Creating a new tag is allowed.")
            i += 2 if ("=" not in a and name in GIT_TAG_LONG_ARG) else 1
            continue
        if a.startswith("-") and len(a) > 1:
            letters = a[1:]
            for k, c in enumerate(letters):
                if c == "d":
                    block("git tag -d removes a release tag.")
                if c == "f":
                    block("git tag -f re-points an existing tag. Creating a new tag is allowed.")
                if c in "mFu":
                    i += 2 if k == len(letters) - 1 else 1
                    break
            else:
                i += 1
            continue
        i += 1


GIT_PUSH_LONG = ["all", "branches", "mirror", "delete", "tags", "follow-tags", "no-follow-tags",
                 "dry-run", "porcelain", "force", "force-with-lease", "no-force-with-lease",
                 "force-if-includes", "no-force-if-includes", "repo", "set-upstream", "thin",
                 "no-thin", "quiet", "verbose", "progress", "no-progress", "prune", "verify",
                 "no-verify", "recurse-submodules", "atomic", "no-atomic", "push-option", "ipv4",
                 "ipv6", "signed", "no-signed", "receive-pack", "exec"]
GIT_PUSH_LONG_ARG = {"repo", "push-option", "receive-pack", "exec"}


def check_git_push(rest, gitdir):
    force = delete = tags = follow = mirror = prune = False
    positional, i = [], 0
    while i < len(rest):
        a = rest[i]
        if a == "--":
            positional += rest[i + 1:]
            break
        if a.startswith("--"):
            name = resolve_long(a[2:].split("=", 1)[0], GIT_PUSH_LONG)
            if name in ("force", "force-with-lease"):
                force = True
            elif name == "delete":
                delete = True
            elif name == "tags":
                tags = True
            elif name == "follow-tags":
                follow = True
            elif name == "mirror":
                mirror = True
            elif name == "prune":
                prune = True
            i += 2 if ("=" not in a and name in GIT_PUSH_LONG_ARG) else 1
            continue
        if a.startswith("-") and len(a) > 1:
            letters = a[1:]
            for k, c in enumerate(letters):
                if c == "f":
                    force = True
                if c == "d":
                    delete = True
                if c == "o":
                    i += 1 if k == len(letters) - 1 else 0
                    break
            i += 1
            continue
        positional.append(a)
        i += 1

    if mirror:
        block("git push --mirror force-updates and deletes every remote ref, tags included.")
    if prune:
        block("git push --prune deletes remote refs, which can remove tags.")
    if force and (tags or follow):
        block("git push with a force flag and --tags/--follow-tags can overwrite existing tags.")

    specs, refspecs, j = positional[1:], [], 0
    while j < len(specs):
        if specs[j] == "tag" and j + 1 < len(specs):
            refspecs.append("refs/tags/" + specs[j + 1])
            j += 2
            continue
        refspecs.append(specs[j])
        j += 1

    for spec in refspecs:
        plus = spec.startswith("+")
        s = spec[1:] if plus else spec
        src, dst = s.split(":", 1) if ":" in s else (s, s)
        if ":" in s and src == "" and is_tag(dst, gitdir):
            block("git push :%s deletes a remote tag." % dst)
        if delete and is_tag(s, gitdir):
            block("git push --delete %s deletes a remote tag." % s)
        if (plus or force) and (is_tag(dst, gitdir) or is_tag(src, gitdir)):
            block("force-pushing %s would move an existing tag. Pushing a new tag without force is allowed." % spec)


# ---------------------------------------------------------------- gh / curl

def has_flag(args, *names):
    for a in args:
        for n in names:
            if a == n or a.startswith(n + "="):
                if a.startswith(n + "=") and a.split("=", 1)[1].lower() == "false":
                    continue
                return True
    return False


WRITE_PATH = re.compile(r"(git/refs/tags|(^|/)releases(/|$|\?)|(^|/)rulesets(/|$|\?)|immutable-releases)")
GRAPHQL_MUT = re.compile(r"\b(deleteRef|updateRefs?)\b")


def check_gh(args):
    # gh global flags before the command group are rare; skip any leading options
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("-R", "--repo") else 1
    args = args[i:]
    if not args:
        return
    grp, sub, rest = args[0], (args[1] if len(args) > 1 else ""), args[2:]
    if grp == "release":
        if sub == "delete":
            block("gh release delete removes a release (and frees its tag for deletion).")
        if sub == "delete-asset":
            block("gh release delete-asset mutates a release; fix assets on the draft in the release workflow.")
        if sub == "edit" and has_flag(rest, "--tag", "--target"):
            block("gh release edit --tag/--target re-points a release at another tag or commit.")
        if sub == "upload" and has_flag(rest, "--clobber"):
            block("gh release upload --clobber replaces published assets; only the release workflow may "
                  "clobber, and only on a draft.")
    elif grp == "repo" and sub == "delete":
        block("gh repo delete destroys a repository with all its tags and releases.")
    elif grp == "auth" and sub in ("login", "refresh"):
        if any(re.search(r"admin:org|admin:enterprise|delete_repo", a) for a in rest):
            block("requesting admin:org, admin:enterprise or delete_repo would let an agent edit "
                  "rulesets or delete repos. Org administration is done by the owner in the browser.")
    elif grp == "api":
        check_gh_api(args[1:])


def check_gh_api(args):
    method, has_body, endpoint, i = None, False, None, 0
    arg_opts = {"-H", "--header", "-q", "--jq", "-t", "--template", "--hostname", "--cache",
                "-p", "--preview"}
    body_opts = {"-f", "--raw-field", "-F", "--field", "--input"}
    while i < len(args):
        a = args[i]
        if a in ("-X", "--method"):
            method = args[i + 1] if i + 1 < len(args) else None
            i += 2
            continue
        if a.startswith("--method="):
            method = a.split("=", 1)[1]
        elif a.startswith("-X") and len(a) > 2:
            method = a[2:]
        elif a in body_opts:
            has_body = True
            i += 2
            continue
        elif a.startswith(("--raw-field=", "--field=", "--input=")) or (a[:2] in ("-f", "-F") and len(a) > 2):
            has_body = True
        elif a in arg_opts:
            i += 2
            continue
        elif not a.startswith("-") and endpoint is None:
            endpoint = a
        i += 1
    if endpoint is None:
        return
    m = (method or ("POST" if has_body else "GET")).upper()
    if endpoint.strip("/") == "graphql":
        if any(GRAPHQL_MUT.search(a) for a in args):
            block("GraphQL deleteRef/updateRef(s) deletes or moves refs, tags included.")
        return
    if m not in ("GET", "HEAD") and WRITE_PATH.search(endpoint):
        block("gh api %s %s writes to tags, releases, rulesets or the immutable-releases setting." % (m, endpoint))


def check_curl(args):
    method, has_body, urls, i = None, False, [], 0
    while i < len(args):
        a = args[i]
        if a in ("-X", "--request"):
            method = args[i + 1] if i + 1 < len(args) else None
            i += 2
            continue
        if a.startswith("--request="):
            method = a.split("=", 1)[1]
        elif a.startswith("-X") and len(a) > 2:
            method = a[2:]
        elif a in ("-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--json", "-F", "--form", "-T", "--upload-file"):
            has_body = True
            i += 2
            continue
        elif a in ("-H", "--header", "-u", "--user", "-o", "--output", "-A", "--user-agent", "-w", "--write-out"):
            i += 2
            continue
        elif "api.github.com" in a or "/api/v3/" in a or "/api/graphql" in a:
            urls.append(a)
        i += 1
    m = (method or ("POST" if has_body else "GET")).upper()
    for u in urls:
        if u.rstrip("/").endswith("graphql"):
            if any(GRAPHQL_MUT.search(a) for a in args):
                block("GraphQL deleteRef/updateRef(s) via curl deletes or moves refs.")
        elif m not in ("GET", "HEAD") and WRITE_PATH.search(u.split("api.github.com", 1)[-1]):
            block("curl %s %s writes to tags, releases, rulesets or the immutable-releases setting." % (m, u))


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    if data.get("tool_name") not in (None, "Bash"):
        return 0
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not cmd.strip():
        return 0
    cwd = data.get("cwd") or os.getcwd()
    try:
        check_script(cmd, cwd, 0)
    except Blocked as e:
        sys.stderr.write("BLOCKED: %s\n%s\n" % (e, FOOTER))
        return 2
    except Exception as e:  # a parser bug must not wedge every Bash call
        sys.stderr.write("block-tag-mutation: internal error, command allowed: %r\n" % (e,))
        return 0
    return 0


sys.exit(main())
PY
)

exec python3 -c "$script"
