#!/usr/bin/env bash
# PreToolUse hook (Bash): blocks commands that move, delete or re-create a release tag, mutate a
# published release or a release branch, or weaken the org controls that keep tags immutable.
#
# Rule: "Release Tags Are Immutable" in the workspace AGENTS.md. This hook is defence in depth;
# the org rulesets and immutable releases are the real control.
#
# Scope: only commands that target an in-scope repo are checked. In scope are
# open-platform-model/{core,library,catalog_opm,cli,opm-operator,release-flow-sandbox}. Everything
# else (modules, emil-jacero/opm-modules, the workspace repo, a target that cannot be resolved)
# passes. The target repo is resolved per command:
#   git      the remotes of the repo at cwd (hook input), `cd DIR &&`, `git -C DIR`; for a push
#            with a named remote or URL, that remote only
#   gh       -R/--repo, GH_REPO=, a repos/OWNER/REPO/ api path, else the remotes of cwd
#   curl     a repos/OWNER/REPO/ path in the URL
# Org-level writes (orgs/open-platform-model/rulesets, .../immutable-releases) and token scope
# requests (gh auth with admin:org, admin:enterprise, delete_repo) govern every in-scope repo and
# are always blocked.
#
# The command is tokenized (shlex), not substring-grepped: chained commands (&& || ; | &),
# subshells, $(...) and backticks outside single quotes, bash -c / eval strings, here-strings and
# echo/printf piped into a shell, env-var prefixes and wrappers (env, sudo, xargs, timeout), git
# global options (-C dir, -c k=v) and quoted arguments are all handled. Heredoc bodies are data
# (commit messages, PR bodies) unless the heredoc feeds a shell.
#
# Blocked (in scope):
#   git tag -d/--delete/-f/--force                (creating a tag is not blocked)
#   git update-ref on refs/tags/...
#   git -c alias.X=<tag|push|update-ref ...>, git -c remote.*.mirror=true, -c remote.*.push=+...
#   git push: --mirror, --prune, a delete (:tag, --delete/-d tag), or a force (+tag, --force/-f,
#             --force-with-lease) together with a tag ref or --tags/--follow-tags; a delete whose
#             ref comes from a variable, $(...) or xargs (cannot be checked, fails closed); any
#             push to a release/* branch (cut by automation, changed only through a PR).
#             A ref counts as a tag when it starts with refs/tags/, exists as a local tag, or
#             looks like a release version (v1.2.3, opm-v1.2.3, x/y/v1.2.3) and is not a local
#             or remote-tracking branch.
#   gh release delete | delete-asset, gh release edit --tag/--target/--draft,
#             gh release upload --clobber
#   gh api / curl / wget writes (non-GET, path percent-decoded) on git/refs/tags,
#             git/refs/heads/release/, releases (not releases/generate-notes), rulesets,
#             immutable-releases; GraphQL deleteRef, updateRef(s), create/update/
#             deleteRepositoryRuleset, or a query the hook cannot read (@file missing, $VAR)
#   gh repo delete
#
# Requires python3; without it the hook allows the command (fail open) and says so on stderr.
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "block-tag-mutation: python3 not found, tag-mutation check skipped" >&2
  exit 0
fi

script=$(cat <<'PY'
import json, os, re, shlex, subprocess, sys
from urllib.parse import unquote

FOOTER = (
    "Release tags are immutable in open-platform-model/{core,library,catalog_opm,cli,opm-operator,"
    "release-flow-sandbox}: "
    "no tag under refs/tags/ is ever moved, deleted or re-created, by anyone. Fix a wrong or broken "
    "release by releasing the next version (Go: retract in the new version; CUE/OCI: publish the "
    "next version). Release tags, releases and release/* branches belong to release-please and the "
    "release workflows, not to an agent shell. See "
    "'Release Tags Are Immutable' in the workspace AGENTS.md. If this is a false positive, ask the "
    "user to run the command themselves."
)

ORG = "open-platform-model"
IN_SCOPE = {"core", "library", "catalog_opm", "cli", "opm-operator", "release-flow-sandbox"}

PUNCT = ";&|()<>\n"
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
SIMPLE_WRAPPERS = {"sudo", "command", "exec", "nohup", "time", "builtin", "then", "do", "else",
                   "elif", "if", "while", "until", "!", "{", "}", "stdbuf", "nice", "unbuffer"}
VERSION_TAG = re.compile(r"^(?:[A-Za-z0-9._-]+[/-])*v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?$")
HEREDOC = re.compile(r"(?<!<)<<(?!<)(-?)\s*(?:'([^']+)'|\"([^\"]+)\"|\\?([A-Za-z_][A-Za-z0-9_]*))")
SHELL_LINE = re.compile(r"(^|[\s;&|(/])(?:ba|z|da|k)?sh(\s|$)")
UNKNOWN_REF = re.compile(r"[$`]|\{\}|^\(")
MAX_DEPTH = 4


class Blocked(Exception):
    pass


def block(msg):
    raise Blocked(msg)


def block_in_scope(scope, msg):
    """Block only when scope() says the command targets an in-scope repo."""
    if scope():
        block(msg)


# ---------------------------------------------------------------- scope

def slug_in_scope(slug):
    if not slug:
        return False
    parts = [p for p in re.split(r"[/:]", slug.strip()) if p]
    if len(parts) < 2:
        return False
    owner, name = parts[-2].lower(), parts[-1].lower()
    if name.endswith(".git"):
        name = name[:-4]
    return owner == ORG and name in IN_SCOPE


_remote_cache = {}


def git_remotes(gitdir):
    """{remote name: [url, ...]} for the repo at gitdir; {} when it is not a git repo."""
    if gitdir in _remote_cache:
        return _remote_cache[gitdir]
    out = {}
    try:
        r = subprocess.run(["git", "-C", gitdir, "config", "--get-regexp", r"^remote\..*\.(url|pushurl)$"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=3)
        for line in r.stdout.splitlines():
            key, _, url = line.partition(" ")
            name = key[len("remote."):].rsplit(".", 1)[0]
            out.setdefault(name, []).append(url)
    except Exception:
        pass
    _remote_cache[gitdir] = out
    return out


def looks_like_url(s):
    return "://" in s or re.match(r"^[^/\s]+@[^:/\s]+:", s) is not None or s.startswith(("/", "./", "../"))


def git_in_scope(gitdir, remote=None):
    remotes = git_remotes(gitdir)
    if remote:
        if remote in remotes:
            return any(slug_in_scope(u) for u in remotes[remote])
        if looks_like_url(remote):
            return slug_in_scope(remote)
        return False
    return any(slug_in_scope(u) for urls in remotes.values() for u in urls)


def lazy(fn):
    cache = []

    def get():
        if not cache:
            cache.append(bool(fn()))
        return cache[0]
    return get


# ---------------------------------------------------------------- tokenizing

def scan_quotes(line, state):
    """Return (mask of unquoted positions, state after the line). state is None, "'" or '"'."""
    mask, i = [], 0
    while i < len(line):
        c = line[i]
        if state is None:
            if c == "\\":
                mask += [False, False]
                i += 2
                continue
            if c in "'\"":
                state = c
                mask.append(False)
            else:
                mask.append(True)
        elif state == "'":
            mask.append(False)
            if c == "'":
                state = None
        else:
            mask.append(False)
            if c == "\\":
                mask.append(False)
                i += 2
                continue
            if c == '"':
                state = None
        i += 1
    return mask, state


def split_heredocs(s):
    """Return (script without heredoc bodies, [(introducing line, body)]).

    Only a << outside quotes starts a heredoc, so echo "<<X" does not swallow later lines.
    """
    lines = s.split("\n")
    out, bodies, i, state = [], [], 0, None
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        mask, new_state = scan_quotes(line, state)
        for m in HEREDOC.finditer(line):
            if m.start() >= len(mask) or not mask[m.start()]:
                continue
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
        state = new_state
    return "\n".join(out), bodies


def substitutions(s):
    """Bodies of $(...) and `...` that bash would run: outside single quotes only."""
    found, i, single, double = [], 0, False, False
    while i < len(s):
        c = s[i]
        if c == "\\" and not single:
            i += 2
            continue
        if c == "'" and not double:
            single = not single
        elif c == '"' and not single:
            double = not double
        elif not single and s.startswith("$(", i):
            depth, j = 1, i + 2
            while j < len(s) and depth:
                depth += {"(": 1, ")": -1}.get(s[j], 0)
                j += 1
            found.append(s[i + 2:j - 1] if depth == 0 else s[i + 2:])
            i = j
            continue
        elif not single and c == "`":
            j = s.find("`", i + 1)
            found.append(s[i + 1:j] if j != -1 else s[i + 1:])
            i = (j + 1) if j != -1 else len(s)
            continue
        i += 1
    return found


def tokenize(s):
    lex = shlex.shlex(s, posix=True, punctuation_chars=PUNCT)
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


class Seg:
    def __init__(self, words, sep="", here=None):
        self.words, self.sep, self.here = words, sep, here or []


def segments(s):
    """Split a script into simple commands. sep is the operator before the command."""
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
                    segs.append(Seg(words))
        return segs
    segs, cur, here, sep, nxt, i = [], [], [], "", "", 0
    while i < len(toks):
        t = toks[i]
        if t and all(c in PUNCT for c in t):
            if "<" in t or ">" in t:
                if cur and cur[-1].isdigit():
                    cur.pop()  # fd number of a redirect such as 2>&1
                if t == "<<<" and i + 1 < len(toks):
                    here.append(toks[i + 1])
                i += 2  # drop the redirect target
                continue
            if cur:
                segs.append(Seg(cur, sep, here))
                cur, here = [], []
                sep = ""
            sep += t
            i += 1
            continue
        cur.append(t)
        i += 1
    if cur:
        segs.append(Seg(cur, sep, here))
    return segs


def is_pipe(sep):
    return "|" in sep.replace("||", "")


def echo_text(words):
    """The text an echo/printf would print, best effort (printf escapes decoded)."""
    base = os.path.basename(words[0])
    args = [a for a in words[1:] if not re.match(r"^-[neE]+$", a)]
    text = " ".join(args)
    if base == "printf" or "-e" in words[1:]:
        text = text.replace("\\n", "\n").replace("\\t", "\t")
    return text


def check_script(s, cwd, depth):
    if depth > MAX_DEPTH:
        return
    stripped, bodies = split_heredocs(s)
    for intro, body in bodies:
        if SHELL_LINE.search(intro):
            check_script(body, cwd, depth + 1)
    for inner in substitutions(stripped):
        check_script(inner, cwd, depth + 1)
    prev = None
    for seg in segments(stripped):
        words = strip_prefix(seg.words)
        if words:
            base = os.path.basename(words[0])
            if base == "cd" and len(words) > 1 and not words[1].startswith("-"):
                cwd = os.path.join(cwd, os.path.expanduser(words[1]))
            if base in SHELLS:
                for h in seg.here:
                    check_script(h, cwd, depth + 1)
                if is_pipe(seg.sep) and prev and os.path.basename(prev[0]) in ("echo", "printf") \
                        and not any(re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a) for a in words[1:]):
                    check_script(echo_text(prev), cwd, depth + 1)
        check_segment(seg.words, cwd, depth)
        prev = words


# ---------------------------------------------------------------- dispatch

ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def strip_prefix(seg, env=None):
    i = 0
    while i < len(seg):
        t = seg[i]
        if ASSIGN.match(t):
            if env is not None:
                k, v = t.split("=", 1)
                env[k] = v
            i += 1
            continue
        base = os.path.basename(t.lstrip("`$("))
        if base == "env":
            i += 1
            while i < len(seg) and (seg[i].startswith("-") or ASSIGN.match(seg[i])):
                if env is not None and ASSIGN.match(seg[i]):
                    k, v = seg[i].split("=", 1)
                    env[k] = v
                i += 2 if seg[i] in ("-u", "--unset", "-C", "--chdir") else 1
            continue
        if base == "xargs":
            if env is not None:
                env["__xargs"] = "1"
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
    env = {}
    seg = strip_prefix(seg, env)
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
        check_git(args, cwd, seg, env)
    elif base == "gh":
        check_gh(args, cwd, env)
    elif base in ("curl", "wget"):
        check_http(base, args)


# ---------------------------------------------------------------- git

def resolve_long(name, options):
    if name in options:
        return name
    hits = [o for o in options if o.startswith(name)]
    return hits[0] if len(hits) == 1 else name


def ref_exists(ref, gitdir):
    try:
        r = subprocess.run(["git", "-C", gitdir, "rev-parse", "--verify", "--quiet", ref],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
        return r.returncode == 0
    except Exception:
        return False


def is_branch(name, gitdir):
    if ref_exists("refs/heads/" + name, gitdir):
        return True
    try:
        r = subprocess.run(["git", "-C", gitdir, "for-each-ref", "--count=1", "--format=x",
                            "refs/remotes/*/" + name],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=3)
        return bool(r.stdout.strip())
    except Exception:
        return False


def is_tag(ref, gitdir):
    if not ref:
        return False
    if ref.startswith("refs/tags/"):
        return True
    if ref.startswith("refs/") or ref == "HEAD" or any(c in ref for c in "*?[~^:"):
        return False
    if ref_exists("refs/tags/" + ref, gitdir):
        return True
    return bool(VERSION_TAG.match(ref)) and not is_branch(ref, gitdir)


def is_release_branch(ref):
    return ref.startswith(("release/", "refs/heads/release/"))


def check_git(args, cwd, seg, env):
    gitdir, i, configs = cwd, 0, []
    while i < len(args):
        a = args[i]
        if a == "-C":
            if i + 1 < len(args):
                gitdir = os.path.join(gitdir, os.path.expanduser(args[i + 1]))
            i += 2
            continue
        if a == "-c":
            if i + 1 < len(args):
                configs.append(args[i + 1])
            i += 2
            continue
        if a in ("--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"):
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        break
    repo_scope = lazy(lambda: git_in_scope(gitdir))
    for kv in configs:
        key, _, val = kv.partition("=")
        key = key.lower()
        if key.startswith("alias.") and re.search(r"\b(tag|push|update-ref)\b", val):
            block_in_scope(repo_scope, "git -c %s defines an alias around tag/push/update-ref; run the "
                           "real command so it can be checked." % key)
        if re.match(r"^remote\..+\.mirror$", key) and val.lower() in ("", "true", "yes", "on", "1"):
            block_in_scope(repo_scope, "git -c remote.*.mirror=true turns a push into --mirror.")
        if re.match(r"^remote\..+\.push$", key) and (val.startswith("+") or val.startswith(":")):
            block_in_scope(repo_scope, "git -c remote.*.push with a force or delete refspec.")
    if i >= len(args):
        return
    sub, rest = args[i], args[i + 1:]
    if sub == "tag":
        check_git_tag(rest, repo_scope)
    elif sub == "update-ref":
        if any("refs/tags" in a for a in rest):
            block_in_scope(repo_scope, "git update-ref on refs/tags/ rewrites or deletes a tag.")
        if "--stdin" in rest and any("refs/tags" in t for t in seg):
            block_in_scope(repo_scope, "git update-ref --stdin with refs/tags/ rewrites or deletes a tag.")
    elif sub == "push":
        check_git_push(rest, gitdir, "__xargs" in env)


GIT_TAG_LONG = ["annotate", "sign", "no-sign", "local-user", "force", "delete", "verify", "list",
                "sort", "contains", "no-contains", "merged", "no-merged", "points-at", "message",
                "file", "edit", "no-edit", "cleanup", "create-reflog", "column", "no-column",
                "format", "color", "ignore-case", "omit-empty", "trailer"]
GIT_TAG_LONG_ARG = {"local-user", "sort", "contains", "no-contains", "merged", "no-merged",
                    "points-at", "message", "file", "cleanup", "format", "trailer"}


def check_git_tag(rest, scope):
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--":
            break
        if a.startswith("--"):
            name = resolve_long(a[2:].split("=", 1)[0], GIT_TAG_LONG)
            if name == "delete":
                block_in_scope(scope, "git tag --delete removes a release tag.")
            if name == "force":
                block_in_scope(scope, "git tag --force re-points an existing tag.")
            i += 2 if ("=" not in a and name in GIT_TAG_LONG_ARG) else 1
            continue
        if a.startswith("-") and len(a) > 1:
            letters = a[1:]
            for k, c in enumerate(letters):
                if c == "d":
                    block_in_scope(scope, "git tag -d removes a release tag.")
                if c == "f":
                    block_in_scope(scope, "git tag -f re-points an existing tag.")
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


def check_git_push(rest, gitdir, via_xargs):
    force = delete = tags = follow = mirror = prune = False
    repo_opt, positional, i = None, [], 0
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
            elif name == "repo":
                repo_opt = a.split("=", 1)[1] if "=" in a else (rest[i + 1] if i + 1 < len(rest) else None)
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

    if repo_opt is None and positional:
        remote, specs = positional[0], positional[1:]
    else:
        remote, specs = repo_opt, positional
    scope = lazy(lambda: git_in_scope(gitdir, remote))

    if mirror:
        block_in_scope(scope, "git push --mirror force-updates and deletes every remote ref, tags included.")
    if prune:
        block_in_scope(scope, "git push --prune deletes remote refs, which can remove tags.")
    if force and (tags or follow):
        block_in_scope(scope, "git push with a force flag and --tags/--follow-tags can overwrite existing tags.")
    if delete and via_xargs and not specs:
        block_in_scope(scope, "git push --delete fed by xargs: the refs cannot be checked, so a tag "
                       "delete cannot be ruled out.")

    refspecs, j = [], 0
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
        dele = delete or (":" in s and src == "")
        if dele and UNKNOWN_REF.search(dst):
            block_in_scope(scope, "git push deletes %s, a ref taken from a variable or command "
                           "substitution; it cannot be checked, so a tag delete cannot be ruled out." % dst)
        if is_release_branch(dst):
            block_in_scope(scope, "git push to %s: release branches are cut by the automated action, "
                           "never deleted or force-pushed, and change only through a PR." % dst)
        if ":" in s and src == "" and is_tag(dst, gitdir):
            block_in_scope(scope, "git push :%s deletes a remote tag." % dst)
        if delete and is_tag(s, gitdir):
            block_in_scope(scope, "git push --delete %s deletes a remote tag." % s)
        if (plus or force) and (is_tag(dst, gitdir) or is_tag(src, gitdir)):
            block_in_scope(scope, "force-pushing %s would move an existing tag." % spec)


# ---------------------------------------------------------------- gh / curl / wget

def has_flag(args, *names):
    for a in args:
        for n in names:
            if a == n or a.startswith(n + "="):
                if a.startswith(n + "=") and a.split("=", 1)[1].lower() == "false":
                    continue
                return True
    return False


WRITE_PATH = re.compile(r"(git/refs/tags|git/refs/heads/release/|(^|/)releases(/|$|\?)|(^|/)rulesets(/|$|\?)"
                        r"|immutable-releases)")
NO_SIDE_EFFECT = re.compile(r"/releases/generate-notes/?(\?|$)")
GRAPHQL_MUT = re.compile(r"\b(deleteRef|updateRefs?|(create|update|delete)RepositoryRuleset)\b")
REPO_PATH = re.compile(r"(?:^|/)repos/([^/?#\s]+)/([^/?#\s]+)")
ORG_PATH = re.compile(r"(?:^|/)orgs/([^/?#\s]+)")


def path_scope(path, fallback):
    """In scope when the path names an in-scope repo or the org itself; fallback() for placeholders."""
    m = REPO_PATH.search(path)
    if m:
        if "{" in m.group(1) or "{" in m.group(2):
            return fallback()
        return slug_in_scope(m.group(1) + "/" + m.group(2))
    m = ORG_PATH.search(path)
    if m:
        return m.group(1).lower() == ORG
    return False


def gh_repo_flag(args, env):
    for k, a in enumerate(args):
        if a in ("-R", "--repo") and k + 1 < len(args):
            return args[k + 1]
        if a.startswith("--repo="):
            return a.split("=", 1)[1]
        if a.startswith("-R") and len(a) > 2:
            return a[2:]
    return env.get("GH_REPO")


def check_gh(args, cwd, env):
    flag = gh_repo_flag(args, env)
    cwd_scope = lazy(lambda: git_in_scope(cwd))
    scope = lazy(lambda: slug_in_scope(flag)) if flag else cwd_scope
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("-R", "--repo") else 1
    args = args[i:]
    if not args:
        return
    grp, sub, rest = args[0], (args[1] if len(args) > 1 else ""), args[2:]
    if grp == "release":
        if sub == "delete":
            block_in_scope(scope, "gh release delete removes a release (and frees its tag for deletion).")
        if sub == "delete-asset":
            block_in_scope(scope, "gh release delete-asset mutates a release; fix assets on the draft in "
                           "the release workflow.")
        if sub == "edit" and has_flag(rest, "--tag", "--target"):
            block_in_scope(scope, "gh release edit --tag/--target re-points a release at another tag or commit.")
        if sub == "edit" and has_flag(rest, "--draft"):
            block_in_scope(scope, "gh release edit --draft turns a published release back into a draft.")
        if sub == "upload" and has_flag(rest, "--clobber"):
            block_in_scope(scope, "gh release upload --clobber replaces published assets; only the release "
                           "workflow may clobber, and only on a draft.")
    elif grp == "repo" and sub == "delete":
        target = next((a for a in rest if not a.startswith("-")), None)
        block_in_scope(lazy(lambda: slug_in_scope(target)) if target else scope,
                       "gh repo delete destroys a repository with all its tags and releases.")
    elif grp == "auth" and sub in ("login", "refresh"):
        if any(re.search(r"admin:org|admin:enterprise|delete_repo", a) for a in rest):
            block("requesting admin:org, admin:enterprise or delete_repo would let an agent edit "
                  "rulesets or delete repos. Org administration is done by the owner in the browser.")
    elif grp == "api":
        check_gh_api(args[1:], cwd, scope)


def graphql_text(args, cwd):
    """(query text, readable). A query from a missing @file or a bare $VAR is unreadable."""
    texts, readable, k = [], True, 0
    while k < len(args):
        a, val = args[k], None
        if a in ("-f", "-F", "--raw-field", "--field") and k + 1 < len(args):
            val = args[k + 1]
            k += 1
        elif a[:2] in ("-f", "-F") and len(a) > 2:
            val = a[2:]
        elif a.startswith(("--raw-field=", "--field=")):
            val = a.split("=", 1)[1]
        k += 1
        if val is None:
            continue
        key, _, v = val.partition("=")
        if v.startswith("@") and a.startswith(("-F", "--field")):
            try:
                with open(os.path.join(cwd, os.path.expanduser(v[1:]))) as f:
                    v = f.read()
            except Exception:
                readable = False
        if re.match(r"^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$", v.strip()):
            readable = False
        texts.append(v)
    return "\n".join(texts), readable


def check_gh_api(args, cwd, scope):
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
    endpoint = unquote(endpoint)
    m = (method or ("POST" if has_body else "GET")).upper()
    if endpoint.strip("/") == "graphql":
        text, readable = graphql_text(args, cwd)
        named = re.search(r"open-platform-model", text) and any(r in text for r in IN_SCOPE)
        gscope = lazy(lambda: named or scope())
        if GRAPHQL_MUT.search(text):
            block_in_scope(gscope, "GraphQL deleteRef/updateRef(s)/RepositoryRuleset mutations move or "
                           "delete refs or weaken rulesets.")
        if not readable:
            block_in_scope(gscope, "gh api graphql with a query the hook cannot read (@file or $VAR); "
                           "inline the query so it can be checked.")
        return
    if m in ("GET", "HEAD") or not WRITE_PATH.search(endpoint) or NO_SIDE_EFFECT.search(endpoint):
        return
    block_in_scope(lazy(lambda: path_scope(endpoint, scope)),
                   "gh api %s %s writes to tags, releases, release branches, rulesets or the "
                   "immutable-releases setting." % (m, endpoint))


def check_http(tool, args):
    method, has_body, urls, i = None, False, [], 0
    while i < len(args):
        a = args[i]
        if a in ("-X", "--request", "--method"):
            method = args[i + 1] if i + 1 < len(args) else None
            i += 2
            continue
        if a.startswith(("--request=", "--method=")):
            method = a.split("=", 1)[1]
        elif tool == "curl" and re.match(r"^-[A-Za-z]*X", a):
            letters = a[1:]
            k = letters.index("X")
            if k == len(letters) - 1:
                method = args[i + 1] if i + 1 < len(args) else None
                i += 2
                continue
            method = letters[k + 1:]
        elif a in ("-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--json", "-F",
                   "--form", "-T", "--upload-file", "--post-data", "--post-file", "--body-data",
                   "--body-file"):
            has_body = True
            i += 2
            continue
        elif a.startswith(("--post-data=", "--post-file=", "--body-data=", "--body-file=")):
            has_body = True
        elif a in ("-H", "--header", "-u", "--user", "-o", "--output", "-A", "--user-agent", "-w",
                   "--write-out", "-O", "--output-document"):
            i += 2
            continue
        elif "api.github.com" in a or "/api/v3/" in a or "/api/graphql" in a:
            urls.append(unquote(a))
        i += 1
    m = (method or ("POST" if has_body else "GET")).upper()
    for u in urls:
        path = u.split("api.github.com", 1)[-1]
        if u.rstrip("/").endswith("graphql"):
            named = re.search(r"open-platform-model", " ".join(args)) and any(r in " ".join(args) for r in IN_SCOPE)
            if named and any(GRAPHQL_MUT.search(a) for a in args):
                block("GraphQL deleteRef/updateRef(s)/RepositoryRuleset mutation via %s." % tool)
        elif m not in ("GET", "HEAD") and WRITE_PATH.search(path) and not NO_SIDE_EFFECT.search(path):
            block_in_scope(lazy(lambda: path_scope(path, lambda: False)),
                           "%s %s %s writes to tags, releases, release branches, rulesets or the "
                           "immutable-releases setting." % (tool, m, u))


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
