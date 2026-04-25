# apt & dpkg — Package Management Internals

## apt update vs apt upgrade

These are two separate operations that are often confused:

| Command | What it does |
|---|---|
| `apt update` | Fetches the package index from configured repos — updates the list of available versions. Installs nothing. |
| `apt upgrade` | Installs newer versions of already-installed packages, based on the index. Does not add or remove packages. |
| `apt dist-upgrade` | Same as upgrade, but also handles dependency changes (new/removed packages). Ansible uses this. |

**Order is mandatory:** `apt update` must run before `apt upgrade`. Without it, `apt upgrade`
works against stale metadata and may not find newer versions.

In Ansible, `update_cache: yes` inside `ansible.builtin.apt` runs `apt update` automatically
before the upgrade.

## dpkg — the low-level package tool

`apt` is a frontend. The actual package installation is done by `dpkg`.

```bash
# Show package state
dpkg -l <package>

# Check for broken/incomplete installations
dpkg --audit

# Configure packages that were unpacked but not configured
dpkg --configure -a
dpkg --configure --pending   # same thing

# Fix broken dependencies
apt --fix-broken install -y

# Reinstall a package (re-download + overwrite existing files)
apt-get install --reinstall <package>
```

## What `dpkg --audit` detects

| Output | Meaning |
|---|---|
| Trigger processing not yet done | Package installed but post-install triggers pending |
| Half-installed packages | Download or unpack interrupted mid-process |
| (no output) | dpkg state is clean |

Run `dpkg --configure -a` after any interrupted upgrade to complete pending configuration.

## apt cache

Downloaded `.deb` files are cached in `/var/cache/apt/archives/`.

```bash
apt-get clean       # remove all cached .deb files
apt-get autoclean   # remove only outdated cached versions
```

If a `.deb` is partially downloaded (e.g. disk ran out of space), it stays in the cache.
Subsequent `apt upgrade` tries to install the corrupt file and fails.
Fix: run `apt-get clean` to remove it, then upgrade again.

## Checking what needs upgrading

```bash
apt list --upgradable
apt-get -s upgrade   # simulate upgrade (dry run, no changes)
```

## Related

- [ELF Binary Corruption](elf-binary-corruption.md)
- [LVM Thin Provisioning](lvm-thin-provisioning.md)
