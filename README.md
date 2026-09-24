# Open Platform Model workspace

The shared layer for working on [Open Platform Model](https://opmodel.dev) across all its repos at
once: agent instructions (`AGENTS.md`, `.claude/`), the workspace `Taskfile.yml` and `.tasks/`,
and the prose style guide (`STYLE.md`). Each OPM repo is cloned beside these files as its own git
checkout and is gitignored here.

## Getting started

Requires `git`, [Task](https://taskfile.dev), [CUE](https://cuelang.org) and Go.

```bash
git clone https://github.com/open-platform-model/workspace.git open-platform-model
cd open-platform-model
task workspace:clone            # GIT_PROTOCOL=ssh task workspace:clone for SSH remotes

export CUE_REGISTRY='opmodel.dev=ghcr.io/open-platform-model,testing.opmodel.dev=ghcr.io/open-platform-model,registry.cue.works'
export OPM_REGISTRY="$CUE_REGISTRY"
task --list
```

Every OPM module resolves anonymously from GHCR; no local registry is needed. Start with
`AGENTS.md`: it routes each kind of task to the right repo.

## Claude Code

Start Claude Code at the workspace root. `AGENTS.md` and `.claude/` load automatically.

- **Personal settings** go in `.claude/settings.local.json` and personal routing in
  `CLAUDE.local.md`. Both are gitignored.
- **Search across repos**: `.gitignore` hides the child repos from git, and `.ignore` re-exposes
  them to ripgrep, so Grep and Glob at the root still search every checkout. When you clone a new
  repo in, add it to both files.
- **@-mention autocomplete across repos**: the built-in picker stops at nested `.git` directories
  ([anthropics/claude-code#94991](https://github.com/anthropics/claude-code/issues/94991)). To work
  around it, point the `fileSuggestion` setting in your user settings (`~/.claude/settings.json`)
  at the bundled script. The path must be absolute:

  ```json
  {
    "fileSuggestion": {
      "type": "command",
      "command": "/absolute/path/to/open-platform-model/.claude/hooks/file-suggestion.sh"
    }
  }
  ```

  The script needs `rg` ([ripgrep](https://github.com/BurntSushi/ripgrep)).
