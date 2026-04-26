# Backup Strategy

## What backups protect against

Different backup designs protect against different failures. Knowing which threat
each layer covers prevents the false confidence of "I have backups" when the
backups don't cover the actual risk.

| Threat                              | Local snapshot | Off-host copy | Off-site immutable |
|-------------------------------------|:--------------:|:-------------:|:------------------:|
| Application bug deletes data        |       ✓        |       ✓       |         ✓          |
| Filesystem corruption               |       ✗        |       ✓       |         ✓          |
| Single-host hardware failure        |       ✗        |       ✓       |         ✓          |
| Site loss (fire, theft)             |       ✗        |       ✗       |         ✓          |
| Ransomware encrypts everything online|      ✗        |       ✗       |         ✓          |
| Operator error (rm -rf /)           |       ✗        |    partial    |         ✓          |

A "complete" backup story has all three layers. Skipping one means accepting
the threats in that column.

## 3-2-1 rule

The classical guideline: **3 copies of data, on 2 media types, 1 off-site**.

- Original (live data)
- Local backup (different disk on same host)
- Off-site backup (different location)

For homelab: original + on-host backup is one layer; CIFS-replicated to NAS is
the second; restic to a remote object-store is the third.

## Off-site with immutability — restic + append-only

Restic is a deduplicating backup tool. It encrypts before upload, deduplicates
across snapshots, and supports many backends (S3, B2, REST, SFTP).

The key property for ransomware resistance is **append-only access** at the
backend layer:

```bash
restic init --repo s3:s3.amazonaws.com/my-backups
restic backup --repo s3:s3.amazonaws.com/my-backups /var/data
```

| Concept           | Why it matters                                                        |
|-------------------|-----------------------------------------------------------------------|
| Encrypted at rest | Backend operator can't read your data                                 |
| Deduplicated      | Daily backups of the same data are cheap                              |
| Append-only       | Backup credential cannot delete past snapshots                        |

The append-only property comes from the *backend credential*, not restic itself.
Configure your backend so the credential restic uses can `PUT` and `GET` but
not `DELETE`. With S3, that's an IAM policy without `s3:DeleteObject`. With
a self-hosted REST server, it's `--append-only` mode.

Why this matters: if an attacker gets onto your backup-source host, they have
the restic password. With normal credentials they can run `restic forget --prune`
and erase all history. With append-only credentials, they can't — the worst
they can do is upload garbage. Old snapshots remain restorable.

Pruning (the necessary operation that actually frees backend space) runs
separately from a different host with full credentials, on a schedule you control.

## Retention as a function of recovery requirements

Retention isn't "keep as much as I can afford". It's "how far back might I
realistically need to recover?":

| Backup tier       | Typical retention                                            |
|-------------------|--------------------------------------------------------------|
| Database dumps    | 7 daily, 4 weekly, 6 monthly                                 |
| Application data  | Same — point-in-time recovery aligned with DB                |
| Media files       | Less aggressive — they don't change. 1 monthly is often enough |
| System configs    | Forever — they're tiny and infinitely useful                 |

Restic implements this via tag policies:

```bash
restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune
```

The `--keep-X` flags are not "delete older than X" — they're "keep one snapshot
per period for the last N periods". A snapshot can satisfy multiple keep-rules
(today's snapshot is "today's daily" *and* "this week's weekly").

`--prune` is what actually frees space. Without it, snapshots are merely marked
as forgotten in the index but data blobs remain. Run prune separately with
full credentials from a dedicated host.

## Local backup — find -mtime retention

For simple local backup retention without restic:

```bash
find /backups -name "*.sql.gz" -mtime +14 -delete
```

| Flag              | Meaning                                                              |
|-------------------|----------------------------------------------------------------------|
| `-name "*.sql.gz"`| Match files by glob — don't delete unrelated files in the same dir   |
| `-mtime +14`      | Modified more than 14 days ago. **`+` is critical** — without it, you delete files modified *exactly* 14 days ago |
| `-delete`         | Action: remove. Run without `-delete` first to preview                |

Always preview first:

```bash
find /backups -name "*.sql.gz" -mtime +14   # list, don't delete
find /backups -name "*.sql.gz" -mtime +14 -delete   # delete after verifying
```

`-mtime` is in **days**. For more granular retention use `-mmin` (minutes).
For "older than this specific date" use `-newermt` with a reference timestamp.

## Restore is the only test that matters

A backup that has never been restored is not a backup — it's a hopeful file.

| Restore test cadence  | What to verify                                                |
|-----------------------|---------------------------------------------------------------|
| Per backup            | File is non-empty, header is parseable (`zcat ... \| head`)   |
| Quarterly             | Full restore to a scratch host. Compare row counts            |
| Yearly                | Disaster scenario: rebuild a service from backups only        |

Add a `verification:` table to your backup runbook:

```markdown
| Date       | Scope             | Result | Notes                |
|------------|-------------------|--------|----------------------|
| 2026-01-15 | postgres full     | OK     | 3min restore         |
| 2026-04-10 | nextcloud config  | OK     | files matched        |
```

Empty rows mean the restore was never tested. That's the column that needs to
be full before you trust the backup story.

## What backups don't include

Document explicitly what is *not* backed up. Common omissions:

- Container images (re-pullable from registries — usually fine to skip)
- TLS private keys (regenerable via `tailscale cert` or Let's Encrypt — fine)
- OS state (re-installable from configuration — fine if config is in IaC)
- **Secrets/env files** (often forgotten — must be backed up if not in a vault)

The "fine to skip" items rely on external assumptions (registry availability,
ACME working). When the assumption breaks during recovery, the absence becomes
expensive. Document the assumption next to each item.

## Related

- [PostgreSQL Operations](../database/postgresql-ops.md)
- [Runbook Methodology](runbook-methodology.md)
- [CIFS Automount](../storage/cifs-automount.md)
