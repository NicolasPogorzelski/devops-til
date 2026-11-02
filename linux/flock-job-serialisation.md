# flock: One Job at a Time

## The problem

Two scheduled jobs that must never touch the same resource at once, started by two independent
timers. Most of the time their windows do not overlap. The one night they do, the second job either
corrupts something or - the better case - refuses and fails.

SnapRAID is the second case. A second `snapraid` process finds the array lock held and exits with an
error instead of waiting. In this homelab the daily sync starts at 23:00 and the weekly scrub at
Sunday midnight. A sync normally takes four to six minutes, so an hour of slack looks generous - until
a sync that resizes the parity runs for more than thirty. Without coordination the scrub then fails,
the week goes without one, and `SnapRAIDScrubStale` fires ten days after the last good run.

## What flock is

`flock` (package `util-linux`, `/usr/bin/flock` on Debian) runs a command while holding a lock on a
file. The file is only a meeting point; it stays empty. What matters is who holds the lock on it.

Picture a single key on a hook by a door. Whoever wants in takes the key; whoever finds the hook
empty waits until the key comes back.

```bash
flock /run/lock/snapraid-maintenance.lock /usr/local/sbin/snapraid-maintenance.sh scrub
```

1. `flock` opens the lock file (creating it if needed) and asks the kernel for an exclusive lock
   (`flock(2)`).
2. Free: it gets the lock and runs the command.
3. Held by another process: it **blocks** until the lock is released, then runs the command.
4. When the command exits, `flock` exits, its file descriptor closes, and the kernel releases the
   lock - also when the command crashed or was killed. A lock cannot be left behind by a dead process.

Useful options, from `man flock`:

| Option | Effect |
|---|---|
| (none) | Wait as long as it takes |
| `-n` / `--nonblock` | Do not wait; exit 1 (or the code given by `-E`) if the lock is held |
| `-w N` / `--timeout N` | Wait at most N seconds, then give up |
| `-s` / `--shared` | Shared lock: any number of shared holders, but none while an exclusive one is held |
| `-o` / `--close` | Close the lock descriptor before running the command (see the caveat below) |

## Here

`snapraid_maintenance` runs sync, scrub and status from one template unit,
`snapraid-maintenance@.service`, so one line covers all three:

```ini
# Before
ExecStart=/usr/local/sbin/snapraid-maintenance.sh %i
# After
ExecStart=/usr/bin/flock /run/lock/snapraid-maintenance.lock /usr/local/sbin/snapraid-maintenance.sh %i
```

A Sunday sync still running at midnight now makes the scrub wait, and the scrub starts the moment
the sync ends. Recorded as part of
[KE-33](../../homelab-server-architecture/docs/platform/known-errors.md#ke-33).

**Interaction with the shutdown guard.** A unit waiting inside `flock` is already `active` to
systemd. The host's shutdown script asks vm102 whether the scrub unit is active and waits while it is,
so a scrub still queued behind the sync holds the shutdown too. The guard gives up after 180 minutes
and then keeps the host up for the night, which bounds the case of a sync that never ends.

## Caveats

- **Advisory, not mandatory.** The lock binds only processes that ask for it. A `snapraid sync`
  started by hand outside `flock` ignores it - and then meets SnapRAID's own lock, which fails fast.
- **Children inherit the descriptor.** A command that starts a background process passes the open
  lock file to it, and the lock lives as long as that child. `-o` closes the descriptor before the
  command runs; it cannot be combined with holding the lock over a long command, so it fits only
  commands that hand off to a daemon.
- **Keep the lock file on a local filesystem.** `/run/lock` is a tmpfs, emptied at boot, which is
  right for a lock. On network filesystems such as CIFS, locks may not be honoured at all (see
  [SQLite on CIFS Locking](../storage/sqlite-on-cifs-locking.md)).
- **No wait limit by default.** A job that hangs holding the lock blocks every later one. Here the
  shutdown guard bounds it; elsewhere `-w` does.

## Why it matters

Two schedules that "never overlap" overlap on the night one job runs long. `flock` turns that night
from a failed job into a delayed one, with one line and no extra state. The same pattern serialises
cron jobs, backup scripts and deploy hooks that must not run twice at once.
