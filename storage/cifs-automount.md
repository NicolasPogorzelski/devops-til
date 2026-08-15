# CIFS via systemd Automount (Reboot-Safe Network Mounts)

## The problem

Hard-mounting a network share at boot via `/etc/fstab` blocks startup if the share
is temporarily unavailable. On a Proxmox host where storage runs in its own VM,
this creates a chicken-and-egg dependency: the host won't finish booting until
the storage VM (which the host is supposed to start) is up.

`systemd automount` solves this: the mount unit is only activated when the
mountpoint is first accessed.

## How automount works

```
A process accesses /mnt/smb/foo
        v
systemd-automount intercepts
        v
Triggers <mountpoint>.mount unit
        v
Process gets the mounted filesystem
```

Two units cooperate per mountpoint:
- `mnt-smb-foo.mount` - the actual mount
- `mnt-smb-foo.automount` - the trigger that activates the mount on access

The automount unit is enabled at boot. The mount unit is started lazily.

## fstab syntax for automount

```
//<server>/<share> /mnt/smb/<name> cifs \
  credentials=/etc/smb-credentials,\
  x-systemd.automount,\
  x-systemd.idle-timeout=600,\
  noauto,\
  uid=1000,gid=1000,\
  vers=3.0 \
  0 0
```

| Option | Purpose |
|---|---|
| `x-systemd.automount` | systemd-fstab-generator creates an `.automount` unit alongside the `.mount` unit |
| `x-systemd.idle-timeout=600` | Unmount after 10 minutes of inactivity |
| `noauto` | Don't mount at boot - wait for first access |
| `credentials=<path>` | Path to a credentials file (chmod 600, contains username/password) |
| `vers=3.0` | Force SMB3 (avoid SMB1, deprecated and insecure) |
| `uid=1000,gid=1000` | Map share ownership to a specific local UID/GID |

## Inspecting mount state

```bash
findmnt -t cifs                    # all CIFS mounts
findmnt -T /mnt/smb/foo            # which mount covers this path
systemctl list-units --type=mount  # all currently active mount units
systemctl list-units --type=automount  # active automount triggers
```

## The boot-trigger pattern - and why my version of it was theatre

The idea: services access bind-mounted CIFS paths during their own startup, before anything
triggers the automount, and start against an empty directory. So add a oneshot unit that touches
every `/mnt/smb/*` early and forces the mounts up.

I ran this for months:

```bash
# /usr/local/sbin/trigger-smb-automounts.sh - DON'T. Kept here as a specimen.
for d in /mnt/smb/*; do
  timeout 3s ls -la "$d"/. >/dev/null 2>&1 || true
done
```

```ini
# After=network-online.target
```

**Two independent reasons it could never work** (found 2026-07-14, by reading the boot journal
instead of the unit):

1. **Ordering.** On a Proxmox host, `network-online.target` is reached *before*
   `pve-guests.service` starts the storage VM. Measured on one boot: trigger at `12:16:15`,
   VM started at `12:16:23`. It poked automounts whose SMB server did not exist yet. **No boot
   ordering can fix this class** - the server is a guest of the machine doing the mounting. Lazy,
   on-access mounting is the *only* mechanism that works.
2. **`|| true` swallowed every error.** The unit reported success unconditionally, forever. It
   passed its positive test every single boot while achieving nothing.

### Replace it with a check that can fail

If the job cannot be "make it work", make it **"prove it worked"**. Run *after* the guests, force
each automount to resolve, and exit non-zero if any path is not CIFS:

```bash
#!/usr/bin/env bash
set -uo pipefail          # NOT -e: we want to collect all failures, not abort on the first
shopt -s nullglob

failed=()
for d in /mnt/smb/*; do
  [[ -d "$d" ]] || continue
  timeout 30s ls -1 "$d"/. >/dev/null 2>&1 || true    # the access IS the trigger

  # Identity, not existence: a bind over a failed mount reports ext4 (the dir underneath).
  fstype="$(findmnt -no FSTYPE --target "$d" 2>/dev/null | tail -1)"
  [[ "$fstype" == "cifs" ]] || failed+=("$d (fstype=${fstype:-none})")
done

if (( ${#failed[@]} > 0 )); then
  printf 'SMB mount check FAILED:\n'; printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
echo "SMB mount check OK"
```

```ini
[Unit]
After=pve-guests.service network-online.target   # after the storage VM exists
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/check-smb-mounts.sh
```

A failing unit is exported by `node_exporter --collector.systemd` and raises an alert. That turns
a silent boot-time mount failure into a page - which is the entire difference between the old unit
and the new one.

**Test the negative case, always.** The old unit passed its positive test for months. Prove the new
one fails when it should:

```bash
mkdir /mnt/smb/zz-test                        # a path that is not a mount
systemctl restart smb-mounts-check.service    # must fail, exit 1
curl -s localhost:9100/metrics | grep 'smb-mounts-check.*failed'   # must show ... 1
rmdir /mnt/smb/zz-test && systemctl reset-failed smb-mounts-check.service
```

## Field report: one missing option, one month of failure (KE-15)

The theory at the top of this file was written *before* the incident it describes. Knowing the
mechanism did not prevent it - **one fstab line was missing `x-systemd.automount`**, and nothing
ever checked:

```
//vm102/Books-service  /mnt/smb/books     cifs  _netdev,nofail,x-systemd.automount,...   # fine
//vm102/Books          /mnt/smb/books-rw  cifs  _netdev,nofail,noatime,...               # BROKEN
```

Without the option, systemd tries the mount **once**, at boot, against a VM the host has not
started yet. It fails (`mount error(113): could not connect`), `nofail` lets the boot continue,
and **systemd never retries**. The unit sits in `failed` forever. Downstream: the LXC bind exposes
the empty directory underneath (on the host's root LV), the container's service cannot write
there, and it failed every two minutes for a month behind a green dashboard.

**The audit that would have caught it in one second - run it on every host with CIFS mounts:**

```bash
grep '/mnt/smb/' /etc/fstab | grep -v x-systemd.automount   # must print nothing
```

Two more things the incident taught:

- **The failure signature, seen from inside the container:** `findmnt /books-rw` reports
  `ext4 /dev/mapper/pve-root[/mnt/smb/books-rw]` instead of `cifs`. That is the bind showing the
  bare directory under the failed mount. `mountpoint -q` says "yes, it's a mountpoint" - because
  the bind *is* one. Existence is not identity (see
  [mount existence vs identity](../linux/mount-existence-vs-identity.md)).
- **A container's bind does not heal when the host mount comes back.** The namespace was set up
  while the mount was down. `pct reboot <ctid>` is required.

**Documentation is not a control.** This file described the chicken-and-egg problem correctly and
in detail while the fleet had a live instance of it. What closes the gap is the `grep` above, plus
a unit that fails loudly - not prose.

## Hard rule: no databases on CIFS

SQLite (and any other DB relying on POSIX file locking semantics) is unreliable
on CIFS/SMB mounts. Symptom: `database is locked` errors under concurrent access.

Architectural rule: no SQLite/PostgreSQL data directories on automount-backed
network shares. Use local block storage for runtime; CIFS is fine for *backups*
since they are write-once + read-on-restore.

## App-state vs uploads - a generalizable split

The "no DBs on CIFS" rule generalizes:

| Data class                            | Storage tier                  | Why                                       |
|---------------------------------------|-------------------------------|-------------------------------------------|
| Application state (DBs, runtime locks) | Local block storage           | POSIX semantics, low-latency, exclusive   |
| User uploads / large files             | CIFS-mounted shared storage   | Capacity, central backup, multi-host read |
| Cached/derived data                    | Local SSD                     | Speed; regeneratable on loss              |
| Backups                                | CIFS / off-site               | Write-once, occasional read on restore    |

A service like Nextcloud hits this split directly: the SQLite/MariaDB DB lives
on local storage, while user files live on the CIFS-mounted media pool. Nextcloud's
external storage feature is the integration point.

Encoding this split per service in the runbook prevents future "we moved everything
to the NAS to save space and now Vaultwarden is broken" incidents.

## Inspection toolkit

```bash
findmnt -t cifs                    # all current CIFS mounts on this host
findmnt -T /mnt/smb/foo            # which mount unit covers this path
findmnt --target /mnt/smb/foo --json   # parseable for scripts
mount | grep cifs                  # legacy form, less structured
systemctl list-units --type=mount  # active mount units, includes auto-generated
systemctl list-units --type=automount  # active automount triggers
systemctl status mnt-smb-foo.automount # detailed state of a specific automount
```

`findmnt` is the most useful single tool. Unlike `mount`, it understands
mount-point hierarchy and unit naming, and `--json` makes scripted health
checks straightforward.

## Desktop fstab - `_netdev` is not enough when the server is behind Tailscale

The tempting rule is "desktops don't need automount, `_netdev,nofail` is fine." That holds
**only if the CIFS server is reachable the moment `network-online.target` is reached** - i.e.
a plain-LAN NAS. It is false when the server is reached over **Tailscale** (or any WireGuard/VPN
overlay), and that distinction is the whole lesson.

`_netdev` waits for `network-online.target`. That target means "a routable interface is up" -
it does **not** wait for `tailscaled` to finish authenticating and installing the route to the
`100.64.0.0/10` peer. So the boot ordering is:

```
network-online.target  ->  fstab CIFS mount fires  ->  route to 100.x.y.z not up yet  ->  FAIL
                                                      tailscaled finishes a moment later
```

The failure is a race, so it is **intermittent and per-share**: whichever mounts lose the sprint
against `tailscaled` land in `failed`; `nofail` lets the boot continue, and systemd never retries
a plain `.mount`. Field instance (2026-07-23, Bazzite desktop, 5 shares off one Tailscale NAS):
after a reboot, 4 shares were mounted and exactly one sat `failed`:

```
mount error(111): could not connect to 100.x.y.z  Unable to find suitable address.
```

Same credentials, same options, same server as the 4 that worked - the only variable was timing.
The empty mountpoint underneath then shows as an empty folder to the file manager / Jellyfin / ES-DE.

**Fix: use `x-systemd.automount` on the desktop too.** Lazy on-access mounting sidesteps the race
entirely - by the time anything touches the folder, `tailscaled` is long up. This is the same
mechanism as the server case above; the trigger there is a chicken-and-egg VM dependency, here it
is VPN-route-after-`network-online`. Both are "the network isn't really ready when `_netdev` says
it is", and automount is the answer to both.

```
//<server>/<share>  /mnt/<name>  cifs  credentials=<path>,vers=3,uid=1000,gid=1000,_netdev,nofail,noauto,x-systemd.automount  0 0
```

`noauto` frees the mountpoint for the `.automount` unit; keep `_netdev`/`nofail` (harmless). The
generated `.automount` unit is `WantedBy=remote-fs.target` (CIFS = remote fs), so it is pulled at
boot automatically - do **not** `systemctl enable` it (generated units refuse `enable`: "transient
or generated"). Activate without a reboot: unmount the old direct mounts, `systemctl daemon-reload`,
then `systemctl start <name>.automount`; the units go to `active waiting`, and the first `ls` on
the path triggers the real CIFS mount.

Audit for the desktop equivalent of the server `grep`:

```bash
grep -E '\bcifs\b' /etc/fstab | grep -v x-systemd.automount   # any Tailscale-backed share here is a latent boot-race
```

### When a plain `_netdev,nofail` desktop entry *is* fine

If the NAS is on the same L2 LAN (server reachable via a normal DHCP/static route that exists at
`network-online.target`), the plain `_netdev,nofail` entry shown under **fstab entry** below is
sufficient - no VPN hop, no race. The credentials-file and `cifs-utils` notes that follow apply to
both the automount and the plain variant.

### KIO/GVfs is not a real mount

KDE Dolphin mounts network shares on-demand via KIO/GVfs. These are not real
filesystem mounts - they live under `/run/user/1000/gvfs/smb-share:...` and
are invisible to applications. ES-DE, RetroArch, and any other app that needs
a stable path cannot use them.

Verify: `gio mount -l` (GVfs mounts) vs `mount | grep cifs` (real CIFS mounts).
If only GVfs shows it, applications cannot use it.

### Credentials file

Never put passwords in fstab (world-readable). Use a credentials file:

```
/etc/samba/credentials/<name>
---
username=<user>
password=<password>
```

```bash
sudo chmod 600 /etc/samba/credentials/<name>
sudo chown root:root /etc/samba/credentials/<name>
```

### fstab entry

```
//<server>/<share>  /mnt/<name>  cifs  credentials=/etc/samba/credentials/<name>,uid=1000,gid=1000,iocharset=utf8,_netdev,nofail  0  0
```

| Option | Purpose |
|---|---|
| `credentials=` | Path to credentials file (chmod 600) |
| `uid=1000,gid=1000` | Map share to local user - required for apps to read/write |
| `iocharset=utf8` | Unicode filenames (game titles with special characters) |
| `_netdev` | Tell systemd this mount needs the network - delays it until network is up |
| `nofail` | Boot succeeds even if the share is unreachable |

Test without reboot: `sudo mount -a`

Verify: `findmnt /mnt/<name>`

### Arch/CachyOS: install cifs-utils

```bash
paru -S cifs-utils
```

### Immutable OS (Bazzite / Fedora Atomic): rpm-ostree layering

On an `rpm-ostree`-based desktop (Bazzite, Silverblue, Kinoite) the root filesystem
is immutable - there is no live `dnf install`. The kernel CIFS code is built in, but
the userspace helper (`mount.cifs` from `cifs-utils`) may need layering:

```bash
mount.cifs --version || rpm-ostree install cifs-utils   # often already in the base image
```

| Step | Why |
|---|---|
| `mount.cifs --version` | Check first - Bazzite ships `cifs-utils` in the base image, so layering is frequently a no-op |
| `rpm-ostree install` | Layers the package into a **new deployment**; the running system is untouched |
| `systemctl reboot` | The layered package only becomes active in the next boot's deployment |

The `/etc/fstab` + credentials-file steps above are identical - `/etc` is writable
and persists across `rpm-ostree` updates. Only the package-install mechanism differs
from a traditional distro. `sudo mount -a` still works immediately once `mount.cifs`
is present (no reboot needed for the mount itself, only for the layering).

## Related

- [Linux: systemd Basics](../linux/systemd-basics.md)
- [Storage: SnapRAID + MergerFS](snapraid-mergerfs.md)
- [Operations: Runbook Methodology](../operations/runbook-methodology.md)
