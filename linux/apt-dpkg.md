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

## Ansible `apt` module — `upgrade:` modes

Ansible's `ansible.builtin.apt` module exposes three upgrade behaviors:

```yaml
- name: Apt upgrade
  ansible.builtin.apt:
    update_cache: yes
    upgrade: dist
    cache_valid_time: 3600
    autoremove: yes
    clean: yes
```

| `upgrade:` value | Equivalent shell command       | Behavior                                                           |
|------------------|--------------------------------|--------------------------------------------------------------------|
| `safe` / `yes`   | `apt-get upgrade`              | Upgrade installed packages, never remove or add                    |
| `full` / `dist`  | `apt-get dist-upgrade`         | Same plus add/remove packages as needed for dependency resolution  |
| `no` (default)   | (no upgrade)                   | Only `update_cache:` runs                                          |

`dist` is right for systems you actively maintain — it keeps dependency state
clean and lets new dependencies pull in. It can remove packages, so it's not
appropriate for a system where you've manually installed packages outside the
distro's expected dependency graph.

`safe` is the conservative choice: never removes anything. Lower risk, but
over time the dependency graph drifts (orphaned packages, unmet recommends).

For a homelab Debian LXC: `dist` once a week, `autoremove: yes` to clean orphans,
`clean: yes` to free apt cache space.

| Option              | Why                                                                  |
|---------------------|----------------------------------------------------------------------|
| `cache_valid_time`  | Skip `apt update` if the index is younger than N seconds. 3600 = 1h |
| `autoremove: yes`   | After upgrade, `apt autoremove` orphan packages                      |
| `clean: yes`        | After upgrade, `apt-get clean` to remove cached `.deb` files         |

### Why `clean: yes` matters in LXC

`/var/cache/apt/archives/` accumulates `.deb` files indefinitely. On a host with
generous disk it's cosmetic. On an LXC with a 10GB rootfs, an unattended apt
cache can fill the disk after a few months — and an out-of-disk LXC during a
later upgrade is how you get half-installed packages and dpkg corruption.

`clean: yes` after every Ansible-driven upgrade prevents this slow-bleed
disk-fill scenario.

## Reading `apt list --upgradable` output

```
package/repo version arch [upgradable from: old-version]
```

The repo column tells you the *source*: `bookworm-security`, `bookworm-updates`,
or third-party. Useful for prioritizing: security upgrades should be applied
immediately, regular updates can wait for the maintenance window.

```bash
apt list --upgradable 2>/dev/null | grep -E "(security|stable-security)"
```

For automated security-only upgrades, `unattended-upgrades` is the standard
Debian package — configures dpkg to auto-apply security updates only.

## Related

- [ELF Binary Corruption](elf-binary-corruption.md)
- [LVM Thin Provisioning](lvm-thin-provisioning.md)
- [Ansible Configuration](../ansible/configuration.md)
