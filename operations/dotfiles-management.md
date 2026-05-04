# Dotfiles Management

A dotfiles repo is the single-source-of-truth for your developer environment config.
It makes a fresh machine setup reproducible — `git clone` + one script.

## Core Problem

Config files contain machine-specific values (absolute paths, usernames, IPs).
If you commit these verbatim, they break on a different machine or leak private info.

## Template + Render Pattern

Store templates with placeholders. Render to real paths at install time.

**Template** (`templates/homelab-settings.local.json`):
```json
{ "repoPath": "<repo-path>" }
```

**Render** (`install.sh`):
```bash
sed "s|<repo-path>|$REPO_PATH|g" templates/homelab-settings.local.json \
  > "$REPO_PATH/.claude/settings.local.json"
```

The placeholder has no special syntax — `sed` replaces it literally.
Using `|` as the delimiter avoids conflicts with `/` in paths.

## `--dry-run` Flag Pattern

A `write_file()` helper that checks a flag before writing:

```bash
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

write_file() {
  local template="$1" destination="$2"
  if $DRY_RUN; then
    echo "[dry-run] would write: $destination"
  else
    mkdir -p "$(dirname "$destination")"
    sed "s|<repo-path>|$REPO_PATH|g" "$template" > "$destination"
  fi
}
```

Run `./install.sh --dry-run` to preview without touching anything.
Run `./install.sh` to apply.

The flag is passed as a positional argument — `$1`. The `${1:-}` pattern
avoids an unbound variable error when no argument is given (strict mode `set -e`).

## pipx + PATH in the Same Shell Session

`pipx ensurepath` modifies `~/.bashrc` (or `~/.bash_profile`) but does not
update the PATH of the currently running shell. Binaries installed by pipx
are in `~/.local/bin` — which is not on PATH until the next login.

Fix: explicitly export PATH immediately after `pipx ensurepath`:

```bash
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
```

This is only needed in scripts that both install via pipx and then call those
binaries in the same session (like a bootstrap script).

## validate.sh Pattern

A pre-install check script that catches problems before they happen:

1. Template JSON syntax — `python3 -m json.tool` (fast, no extra deps)
2. No hardcoded absolute paths — `grep -rn "/home/"` must return nothing
3. Scripts are executable — `-x` test
4. Required templates exist — `-f` test

Exit 0 = all checks passed. Exit 1 = errors found (printed with context).

Run before `install.sh` to fail early.

## Dotfiles Repo Structure

```
dotfiles/
├── bootstrap.sh        # installs system packages, ansible, claude code
├── install.sh          # renders templates, writes to destination paths
├── validate.sh         # pre-install integrity checks
└── templates/
    ├── gitconfig
    ├── claude-global-settings.json
    └── homelab-settings.local.json
```

## Rebuild Workflow

After a fresh OS install:
1. `./bootstrap.sh` — install tools
2. `./validate.sh` — check templates are intact
3. `./install.sh --dry-run` — preview destination files
4. `./install.sh` — apply

The `bootstrap.sh` → `install.sh` split is intentional:
- `bootstrap.sh` requires sudo and internet access.
- `install.sh` only needs the user's home directory and an already-cloned repo.
- Separation makes `install.sh` safe to re-run on an existing machine.
