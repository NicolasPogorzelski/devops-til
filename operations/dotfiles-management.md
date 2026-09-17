# Dotfiles Management

A dotfiles repo is the single-source-of-truth for your developer environment config.
It makes a fresh machine setup reproducible - `git clone` + one script.

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

The placeholder has no special syntax - `sed` replaces it literally.
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

The flag is passed as a positional argument - `$1`. The `${1:-}` pattern
avoids an unbound variable error when no argument is given (strict mode `set -e`).

## pipx + PATH in the Same Shell Session

`pipx ensurepath` modifies `~/.bashrc` (or `~/.bash_profile`) but does not
update the PATH of the currently running shell. Binaries installed by pipx
are in `~/.local/bin` - which is not on PATH until the next login.

Fix: explicitly export PATH immediately after `pipx ensurepath`:

```bash
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
```

This is only needed in scripts that both install via pipx and then call those
binaries in the same session (like a bootstrap script).

## validate.sh Pattern

A pre-install check script that catches problems before they happen:

1. Template JSON syntax - `python3 -m json.tool` (fast, no extra deps)
2. No hardcoded absolute paths - `grep -rn "/home/"` must return nothing
3. Scripts are executable - `-x` test
4. Required templates exist - `-f` test

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
1. `./bootstrap.sh` - install tools
2. `./validate.sh` - check templates are intact
3. `./install.sh --dry-run` - preview destination files
4. `./install.sh` - apply

The `bootstrap.sh` -> `install.sh` split is intentional:
- `bootstrap.sh` requires sudo and internet access.
- `install.sh` only needs the user's home directory and an already-cloned repo.
- Separation makes `install.sh` safe to re-run on an existing machine.

## Templates rot when the live file is the one that evolves

Checked 2026-09-17: both Claude Code templates in `dotfiles/` were still at the first
commit. The live `~/.claude/settings.json` on the workstation had since gained three
hooks (explain rule, attribution refusal, push refusal); the live project file had
gained a deny list and a guard script that the homelab repository now documents in
`snippets/claude/hooks-reference.json`. Running `install.sh` would have *downgraded*
both. A template is only a source of truth if edits go there first and get rendered
out; here they went to the live files and the template was never told.

The check is a diff, not a reading: `diff <(jq -S . template) <(jq -S . live)` per
managed file, before every `install.sh`. Anything the live side has and the template
lacks is either a change to port back or a reason not to run the installer.

## `uv tool install` where `pipx` is not available

`bootstrap.sh` installs `pipx` with `apt`. On an immutable Fedora workstation there is
no `pipx` and `rpm-ostree install` would need a reboot for a linter. `uv tool install
'ansible-lint==26.6.0'` is the same shape as `pipx install`: an isolated environment
under `~/.local/share/uv/tools/<name>/` and a shim in `~/.local/bin/`. The repository
check only asks `command -v ansible-lint` and that the version matches CI's pin, so
the installer is a workstation detail, not a repository one.

## A gitconfig that drifts changes who you are

The same 2026-09-17 diff that found the two Claude Code templates stale found the third
template stale in the other direction. `templates/gitconfig` still held the identity every
repository's history carries; the live `~/.gitconfig` on the gaming PC had a different
`user.name` and `user.email`, and had had them since at least July - every commit made
from that machine (2026-07-28, 2026-08-13, 2026-09-17) went out under a second identity,
seven of them already public. Nobody chose that. The `--dry-run` diff is what surfaced it,
and the `render()`-based diff in `install.sh` now shows it for every managed file rather
than only for the two JSON ones.

Two rules fall out. First, `user.name` and `user.email` are template material and the
template is the truth: when the live file differs, the live file is the drift, not the
template. Restore with `git config --global user.name/user.email`, and for unpushed commits
`git commit --amend --reset-author --no-edit` picks the corrected identity up. Second, a
credential helper is not template material - the live file's `gh auth git-credential`
entry names a Linuxbrew path that exists on one machine, and `validate.sh` rejects
hardcoded paths for exactly this reason. The template renders identity and behaviour;
the machine adds its own credential plumbing afterwards.

The check that catches the class is one line per machine, before trusting any commit
from it: `git log --format='%an <%ae>' -30 | sort | uniq -c`. Two lines of output is
two identities.

## Commit signing is a per-workstation control

`security-controls.md` in the homelab repository has said since 2026-08-15 that SSH commit
signing is enabled. Measured 2026-09-17: true for the notebook - every non-bot commit since
2026-08-18 carries a `gpgsig` header with the same ed25519 key, 110 of 142 - and false for
the gaming PC, which had no `gpg.format`, no `user.signingkey`, no `commit.gpgsign`, and a
different key. A control that lives in `~/.gitconfig` holds on the machine that has the
config, and the document that describes it does not say which machine that is.

Two measurement details worth keeping. `git log --format=%G?` is the wrong instrument for
"is this signed": without `gpg.ssh.allowedSignersFile` it prints an error per SSH-signed
commit and reports `N`, the same letter as unsigned. `git cat-file commit <sha> | grep -c
^gpgsig` answers the question the config cannot distort. And the signing key can be read
out of any signed commit: the SSHSIG blob's first length-prefixed field after the magic and
version is the public key, so `ssh-keygen -lf` on it gives the fingerprint to compare
against `~/.ssh/*.pub` on the machine in question.

The fix belongs in the gitconfig template, because `~/.ssh/id_ed25519.pub` is a path that
holds on every machine: `gpg.format = ssh`, `user.signingkey = ~/.ssh/id_ed25519.pub`,
`commit.gpgsign = true`. The one step no template can do is registering that machine's
key on GitHub as a *signing* key, which is a separate list from authentication keys.
