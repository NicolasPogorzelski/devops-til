# SQLite on CIFS: Why `database is locked`, and the Local-Copy Workaround

## The problem

A Calibre library lived on a CIFS share (`//storage/Books`). Adding a book from
the LXC host with `calibredb add --with-library /books-rw ...` failed:

```
apsw.BusyError: BusyError: database is locked
  ...
  File ".../calibre/db/schema_upgrades.py", line 18, in __init__
    db.execute('BEGIN EXCLUSIVE TRANSACTION')
```

The obvious guess - "another process holds the DB" - was wrong. The only known
holder was the `calibre-web` container, and the script already **stopped it**
before importing. The lock failure persisted with nothing else open.

## Root cause: byte-range locks don't survive CIFS

SQLite coordinates access with POSIX **advisory byte-range locks** (`fcntl`
`F_SETLK` on specific offsets in the DB file). An `EXCLUSIVE` transaction asks
for a write lock on a byte range. Over a CIFS/SMB mount these `fcntl` lock
requests are translated into SMB lock requests, and most SMB servers + the
Linux CIFS client do **not** implement the advisory semantics SQLite expects -
so the lock request is refused and SQLite reports `database is locked`.

This is *filesystem-level*, not process-level. Stopping every reader/writer does
not help, because the failure is the lock **acquisition** itself, not contention.

> Same family of issue as "SQLite on a network share corrupts / locks up" - the
> SQLite docs explicitly warn against putting a DB on a network filesystem.

## Diagnosis: prove it's the filesystem, not the data

Indication is not diagnosis. A clean control test isolates the layer - same DB,
same binary, only the filesystem differs:

```bash
docker stop calibre-web                       # remove the only other writer

# A) operate directly on CIFS  -> expected to fail
calibredb add --with-library /books-rw   --automerge ignore book.epub   # BusyError

# B) operate on a LOCAL copy of metadata.db -> expected to succeed
mkdir /tmp/lib && cp /books-rw/metadata.db /tmp/lib/
calibredb add --with-library /tmp/lib    --automerge ignore book.epub   # Added book ids: 2042
```

A passes nowhere, B succeeds -> the DB content and the binary are fine; the CIFS
mount is the problem. Diagnosis confirmed.

**Verification trap:** even read commands can hide the failure. `calibredb list
--with-library /books-rw` *also* tries to lock, fails, and (with stderr
suppressed) just prints nothing - which looks like "empty library", not "error".
Always verify against a local copy of the DB, never against the CIFS path.

## Two fixes

### Option 1 - `nobrl` mount option (root fix, but touches the mount)

```
//server/Books /mnt/smb/books-rw cifs ...,nobrl 0 0
```

`nobrl` (`mount.cifs(8)`: "do not send byte-range lock requests to the server")
makes the CIFS client skip lock requests entirely, so SQLite's locking becomes a
local no-op and proceeds. Correct and permanent, but:
- it changes the **host** mount (or the LXC `mp` definition), affecting every
  consumer of that share;
- it disables lock coordination, so it is only safe when access is effectively
  single-writer.

### Option 2 - local-copy + write-back (app-side, no mount change)

When you can't (or don't want to) change the mount, never let SQLite touch the
CIFS file. Snapshot it locally, mutate locally, copy the results back with plain
file ops (which take no byte-range locks):

```
stop the writer (calibre-web)          # consistent snapshot, no concurrent writer
cp  metadata.db  ->  /tmp/work/         # local working copy (local disk, not CIFS)
calibredb add --with-library /tmp/work  # SQLite only ever opens the LOCAL file
tar new book dirs  /tmp/work -> /books  # plain copy: no fcntl locks, CIFS is happy
atomically swap metadata.db back        # write-then-rename on the share
restart the writer
```

Key points:
- **Write files before the DB.** The book files must exist on the share before
  the swapped-in `metadata.db` references them, or the library points at nothing.
- **Atomic DB swap:** `cp work/metadata.db /books/.metadata.db.new && mv -f
  /books/.metadata.db.new /books/metadata.db`. `mv` (rename) is atomic-ish on the
  share, so a reader never sees a half-written DB.
- **`tar` instead of `cp -r`** for the book directories: `tar -C src -cf - . |
  tar -C dst -xf -` merges into existing author folders cleanly and copies no DB
  journals (`--exclude='metadata.db*'`).
- **`mktemp -d` + `trap cleanup EXIT`** so the working dir is removed and the
  writer is always restarted, even on error (see [Bash Scripting Patterns](../linux/bash-scripting-patterns.md)).
- Calibre stores book paths **relative** to the library root, so a DB written
  against `/tmp/work` resolves correctly once it sits at `/books` - as long as the
  book directories were copied to the matching relative paths.

## Durability ordering: delete the source *last*

A subtle data-loss bug in the local-copy workflow - independent of CIFS, it
applies to any "ingest then delete the source" job, especially when no second
copy is kept (here the storage pool was near full, so the source was deleted
after a successful import).

The naive ordering deletes the source as soon as the tool reports success:

```bash
for f in "${files[@]}"; do
    if calibredb add --with-library "$WORK" "$f"; then
        rm -f "$f"          # WRONG: $WORK is a volatile /tmp copy, discarded on exit
    fi
done
# ... only here: tar the new files back to the share + swap metadata.db in
```

The trap: `calibredb add` succeeding means the book is in the **local working
copy** (`/tmp`, removed by the EXIT trap) - *not* on the durable share. The
write-back happens later. If the run dies in between (network drop, server down,
`pipefail` on the `tar`, OOM kill), the source is already gone, the working copy
is wiped, and the book never reached the share. Silent, unrecoverable loss.

Fix - delete only after the data is **durable** (written back *and* referenced):

```bash
imported=()                              # collect, don't delete yet
for f in "${files[@]}"; do
    if calibredb add --with-library "$WORK" "$f"; then
        imported+=("$f")
    else
        mv -f "$f" "$FAILED_DIR/"        # quarantine: not a loss, keep the file
    fi
done

if [ "${#imported[@]}" -gt 0 ]; then
    tar -C "$WORK" --exclude='metadata.db*' -cf - . | tar -C "$LIBRARY" -xf -
    cp "$WORK/metadata.db" "$LIBRARY/.metadata.db.new"
    mv -f "$LIBRARY/.metadata.db.new" "$LIBRARY/metadata.db"
    for f in "${imported[@]}"; do rm -f "$f"; done   # NOW it's safe
fi
```

Why this is safe:
- With `set -e`, a failure before the write-back aborts the script *before* the
  `rm` loop - the sources stay in place and the next run retries them.
- Idempotent retry: `calibredb add --automerge ignore` skips a book already in
  the library, so re-processing a source that *did* make it back is a no-op.
- The general rule: **commit, then acknowledge.** Delete/ack the input only after
  the output is durably persisted - the same invariant as message-queue "ack after
  processing" or "fsync before reporting success". Reordering it from
  *report-success* to *durably-persisted* turns a possible data loss into, at
  worst, a harmless reprocess.

## Takeaways

- SQLite (and anything using `fcntl` byte-range locks) is unreliable on CIFS/NFS;
  `database is locked` there is a *locking-not-supported* signal, not contention.
- Diagnose filesystem-vs-data with a CIFS-vs-local control test before fixing.
- `nobrl` is the root fix when you own the mount and access is single-writer.
- Otherwise keep the DB off the network path: operate on a local copy and write
  results back with lock-free file ops + an atomic rename.
- In an ingest-then-delete job, delete the source **only after** the result is
  durably persisted - never just because the tool reported success into a
  volatile working copy. Combine with `set -e` + an idempotent retry so a crash
  reprocesses instead of losing data.

## See also

- [CIFS via systemd Automount](cifs-automount.md)
- [Bash Scripting Patterns](../linux/bash-scripting-patterns.md) - `mktemp`+`trap`, strict mode, HEREDOC
- [Samba Server Config](samba-server-config.md)
