# CIFS `hard` vs `soft`: When One Dead Share Freezes the Whole Desktop

Why an unreachable SMB server does not produce an error but an unkillable
process, how a single mountpoint propagates that into a full desktop freeze,
and how to find out *which* program keeps poking the dead path.

Companion to [CIFS via systemd Automount](cifs-automount.md) (how automount
works) and [systemd Mount Units](../linux/systemd-mount-units.md) (`_netdev`,
`nofail`, boot-race).

## The symptom that lies

Observed 2026-07-27 on a Fedora-based immutable desktop. Reported symptom:
"the machine hangs after quitting an emulator a few times". The emulator was a
red herring — it was merely the process that happened to touch a network path
first.

Actual state:

```
mount.cifs        D    (uninterruptible sleep)
gvfsd-recent      Dl   wchan: autofs_wait
```

Nothing starts anymore — no browser, no system monitor. The session looks alive
(cursor moves, already-running windows repaint) but every *new* process blocks.

## Why `hard` produces a D-state and not an error

CIFS mounts default to `hard` semantics: if the server does not answer, the
kernel **retries indefinitely** instead of returning an error to userspace.
The waiting process sits in **D state** — uninterruptible sleep.

D state matters because it is not a normal "busy":

- `SIGTERM` and `SIGKILL` are **not delivered** — not even as root
- `Ctrl+C` does nothing
- the process is not schedulable out of the wait; only the I/O completing (or
  being aborted at the transport level) releases it

So "the server is off" does not surface as an error dialog. It surfaces as a
process that can never be cleaned up.

Check the default and the wording for your kernel: `man mount.cifs`, then
`/soft` inside the pager.

## Why *one* mount takes down *everything*

The blocking does not stay local to the app that touched the share. The chain:

```
SMB server offline
  → mount.cifs blocks in the kernel (D)
  → autofs blocks every access to the mountpoint (wchan: autofs_wait)
  → gvfsd-recent blocks (it polls "Recent Files", which reference the share)
  → GVFS is the shared file-access layer for all GTK apps
  → every app launch blocks
```

The desktop-wide freeze needs two ingredients: an unbounded wait, **and** a
central single-purpose daemon that walks the path on a timer. `gvfsd-recent` is
that daemon on GNOME. The equivalent on any server is whatever indexer, backup
agent or monitoring check enumerates mountpoints.

**Transferable rule:** a blocking dependency is only as contained as its least
contained consumer. One shared daemon touching a hung path converts a
per-application stall into a system-wide outage.

## Finding out who actually triggers the mount

This is the reusable part. systemd logs the triggering PID and command for
every automount activation, so the culprits can be counted instead of guessed:

```bash
journalctl --since "<date>" --no-pager -g "Got automount request" \
  | grep -oE "triggered by [0-9]+ \([^)]+\)" \
  | sed -E 's/triggered by [0-9]+ \(([^)]+)\)/\1/' \
  | sort | uniq -c | sort -rn
```

- `-g` — journald-side regex filter (`--grep`), cheaper than piping everything
- `grep -oE` — `-o` prints only the match, not the whole line
- `sed -E 's/…/\1/'` — keep only the capture group (the command name); the PID
  is dropped because it changes per start and would defeat aggregation
- `sort | uniq -c` — `uniq` only collapses *adjacent* duplicates, so the
  preceding `sort` is mandatory
- `sort -rn` — numeric, descending

Result over 7 days (~232 triggers total):

| Trigger | Count | What it is |
|---|---|---|
| `gvfsd-recent` | 162 | GNOME "Recent Files" polling |
| `retroarch` | 42 | emulator scanning content directories |
| `systemd-binfmt` | 23 | binfmt handler registration |
| `missioncenter-*` | 8 | system monitor enumerating filesystems |
| `nautilus-search` | 5 | file-manager search index |

The application everyone blamed accounted for 18%. The file manager's recent-files
daemon accounted for 70% — and it was pointed at a *media* share nobody had
asked it to watch.

**On-demand mounting does not mean "mounts when I want it".** It means "mounts
when *anything* touches the path". Every background indexer counts.

## Unblocking a live system

Order matters. Disarm the trigger before unmounting, or the next access
re-triggers the mount immediately:

```bash
# 1. stop the autofs triggers (.automount, NOT .mount)
sudo systemctl stop var-mnt-storage-{a,b,c}.automount

# 2. force + lazy unmount whatever is still stuck
sudo umount -f -l /mnt/storage/<share>

# 3. restart the user-space file layer
systemctl --user restart gvfs-daemon.service
```

- `-f` (force) aborts the pending CIFS requests — this is what releases the
  D-state process
- `-l` (lazy) detaches the mountpoint from the namespace immediately and defers
  cleanup; without it `umount` itself blocks on the processes still in the path
- step 3 only works *after* step 2 — a D-state process cannot be restarted

Verify: `ps -eo stat --no-headers | grep -c "^D"` must return `0`.

## Fixing it durably

Three levels, increasing containment:

| Approach | Behaviour when server is off | Cost |
|---|---|---|
| `x-systemd.automount` alone (default `hard`) | desktop freezes | none — until it happens |
| `+ soft` `+ mount-timeout` `+ idle-timeout` | access fails with `EIO` after ~5 s | none |
| no `x-systemd.automount` at all (`noauto` only) | nothing happens; manual `mount` | must mount by hand |

The middle option as applied:

```
//<server>/<share>  /mnt/storage/<share>  cifs  credentials=<path>,vers=3,\
uid=1000,gid=1000,_netdev,nofail,noauto,x-systemd.automount,\
soft,x-systemd.mount-timeout=5s,x-systemd.idle-timeout=60s  0 0
```

| Option | Why |
|---|---|
| `soft` | return `EIO` after timeout instead of retrying forever — **the option that prevents the D-state**, everything else is secondary |
| `x-systemd.mount-timeout=5s` | bound how long systemd waits for the mount job; on a LAN a healthy mount completes in well under a second, the default would be 90 s |
| `x-systemd.idle-timeout=60s` | unmount when idle, so a mount established while the server was up does not become a corpse when it goes down |

`soft` trades durability for availability: if the server disappears mid-write,
I/O can be aborted rather than waited out. Acceptable for read-mostly media
shares; for shares under active write load, `hard` plus a reachability gate is
the safer direction.

### The gap `soft` does not close

`soft` governs operations on an **established** mount. The failure above was the
**initial** mount attempt against a dead host — `mount.cifs` blocked in the TCP
connect. `x-systemd.mount-timeout=` bounds that at the systemd job level, but a
job timeout cannot signal a process that is in D state.

Complete elimination of the fault class requires no autofs trigger on that path
at all: either `noauto` without `x-systemd.automount` (manual), or a userspace
mount (GVFS / `gio mount`), where a dead server yields an error dialog because
nothing runs in kernel context.

Know which one you picked and why. "Hardened" and "cannot happen" are different
claims.

## Second-order fix: remove the poller

Options only bound the damage per attempt. Removing the *reason* for the attempt
is cheaper:

- GNOME: Settings → Privacy → File History → off (kills `gvfsd-recent` polling)
- application content/scan directories: point them at the one share they need,
  not the parent of all shares

70% of the trigger volume came from a daemon that had no business on those paths.

## Diagnosis cheatsheet

```bash
# processes stuck in uninterruptible I/O, with the kernel function they wait in
ps -eo pid,stat,wchan:25,comm --no-headers | awk '$2 ~ /D/'

# mount/automount unit state (failed vs activating vs waiting)
systemctl list-units --type=mount --type=automount --all | grep <path>

# which options a generated mount unit actually received
systemctl show <unit>.mount -p Options

# is the peer even reachable? (bash builtin, no nc required)
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/<host>/445' && echo open || echo closed
```

`activating (mounting)` that never leaves that state = a hung mount, not a slow
one. `failed` is the *good* outcome by comparison: it means something returned.

## Takeaways

1. **An unreachable network filesystem is not an error condition by default.**
   `hard` semantics convert unreachability into an unbounded wait, and D state
   makes that wait immune to signals. Choose the failure mode explicitly.
2. **Blast radius is set by the consumers, not by the mount.** Audit *what walks
   the path on a timer* before assuming a stall stays local.
3. **The loudest process is not the cause.** The journal names the triggering
   command for every automount activation — count them instead of blaming the
   application that was on screen.
4. **A symptom that fits two independent defects will fit the wrong one first.**
   The same session also had an unrelated memory leak in an emulator core; both
   presented as "the system hangs".
