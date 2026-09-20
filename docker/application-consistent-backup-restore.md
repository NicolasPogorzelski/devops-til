# Application-Consistent Backup and Restore of Compose Stacks

Learned while building `backup.sh`/`restore.sh` for a GitLab + OpenProject +
XWiki + lldap environment and restoring it onto a freshly created VPS (measured
RTO 21 min from first root login, 11 min of which is the restore script).

## State has more than one shape — each needs its own method

| Shape | Example | Safe method |
|---|---|---|
| plain files, no writer | certificates, `.env`, uploads | copy/tar (uploads: with the application stopped) |
| SQLite | lldap `users.db` | stop the process, copy, start — a copy under a writer can hold half a transaction |
| PostgreSQL | app databases | `pg_dump -Fc` while the server runs; **never** copy the data directory of a running server |
| bundled product | GitLab Omnibus (PostgreSQL + Redis + Gitaly + Rails) | the product's own tool (`gitlab-backup create`), which coordinates the parts |

"Stop everything and tar `/srv`" is the wrong simplification: `pg_dump` and
`gitlab-backup` need *running* processes. The rule that works: stop the
**application** containers (so files and database describe the same moment),
keep the **database** containers running and dump them, leave the product that
guarantees its own consistency alone.

## Why `pg_dump` is consistent and a file copy is not

PostgreSQL writes every change to the write-ahead log first and to the table
files later. A directory copy therefore mixes files from different instants;
recovery at start-up may repair it or silently lose rows. `pg_dump` is a
client that opens one transaction; MVCC gives that transaction a frozen
snapshot regardless of concurrent writers. Bonus: the dump is independent of
the PostgreSQL major version, the data directory is not.

Restore order matters: start **only** the database container (its entrypoint
runs `initdb` and creates role + database from the environment because the
directory is empty), `pg_restore --no-owner -1`, *then* start the application.
If the application starts first, its migrations create the schema and
`pg_restore` fails with "relation already exists".

## The product's backup tool defines *its* state, not the service's

`gitlab-backup create` deliberately excludes `/etc/gitlab`: `gitlab.rb`,
`gitlab-secrets.json` (the key for encrypted database columns — without it,
tokens and 2FA are unreadable after a restore) **and the SSH host keys**.
Without the host keys every `git@` client warns about a changed host key after
a rebuild. The gap was found by diffing the *reinstall checklist* of the
service against the *contents of the set* — the difference is the backup gap.
Restore only onto the same GitLab version; the script records the image tag in
a manifest and refuses a mismatch before touching anything.

## `tar --numeric-owner` under `userns-remap`

tar stores owners as number *and* name and prefers the name on extraction,
looking it up in the target's `/etc/passwd`. Remapped container UIDs
(100000, 101000, 100070) have no names on the host, and a future package could
introduce a name that maps somewhere else. `--numeric-owner` on **create and
extract** makes the result depend only on the number, which a pinned
subordinate range keeps identical across rebuilds.

## A set is a secret

The set holds every `.env`, private TLS keys and `gitlab-secrets.json`. So:
root-only while it is built, group-readable (Debian's `backup` group, which
exists for delegated backup duties) for the off-host pull, and encrypted with
`age` before it leaves the host — the workstation that receives it had no disk
encryption (`lsblk` showed btrfs without a `crypt` layer), which turned "age
later" into "age now". Public key in the repo, identity in the password
manager, on the target host only for the minutes of a restore.

## Small things that cost real time

- `docker compose start web` honours `depends_on` with
  `service_completed_successfully` and **re-runs the one-shot seeder** (~45 s
  of 90 s backup time). `compose start` has no `--no-deps`; accepted, because
  `up --no-deps` may recreate containers.
- Under systemd the umask is 022: create the working directory with
  `install -d -m 700` explicitly, or it is world-listable for a few seconds.
- A helper that ends in `exit` is not caught by `cmd || { … }` — `exit` ends
  the script from inside the function. Combined with `2>/dev/null` at the call
  site this produced a silent failure of the *verifier* while the system was
  fine. Helpers return codes; only the top level exits.
- A `.partial` name plus one `mv` at the end is enough atomicity: prune and
  restore never mistake a half-written set for a complete one.
- Retention counts sets by **name**, never by mtime (rsync and touch move mtime).
- The Debian cloud image ships without `git`; a runbook that starts with
  `git clone` needs `apt-get install -y git` first. Noticed on day 1, not
  written down, repeated on day 3 — the reason a problems log exists.

## Verification is two lists

Machine-checkable: every container `healthy`/`running`, every hostname answers
over TLS (`curl --cacert ca.crt --resolve name:443:ip`). Functional, by a
human: LDAP user accepted in all products, user *without* the group refused
(proves the filters came back), clone over SSH without a host-key warning,
a page and a work package **with attachment** exist. A container can be healthy
with an empty database — the second list is not optional.

## Added after the hand-in day's second half

- **A webhook receiver's `200` means "accepted", not "done".** OpenProject
  answered 200 to every GitLab delivery and linked nothing: the integration
  user lacked the permission to write a comment on the work package. Verify
  the *effect* in the data (`gitlab_merge_requests` table), not the status
  code — and when a query returns nothing, check the join key first (the
  user's login was the e-mail address).
- **"Disabled" for a per-project setting needs a query over all projects.**
  The seeder had created a second project with the wiki module on; the
  instance default for new projects still contained it.
- **URL validators apply outbound policies to URLs that are never called.**
  GitLab refused an External-wiki link to a private address exactly like a
  webhook; the fix is the same per-name allowlist, never the blanket switch.
- **Header defaults at the proxy with "set if absent" semantics** (Caddy
  `?Field`): a floor under every backend without taking a stricter decision
  away from those that set their own. Measure error responses too — Caddy's
  own `401` bypasses the site's header directive.
- **Run a security scanner the way its authors run it.** `docker-bench-security`
  under `sh` (dash) mis-evaluates bash-only tests and reports false WARNs
  (user namespaces "not enabled" on a remapped daemon); under `bash` the
  numbers were right. Read a scanner's errors before its findings.
- **Precision beats breadth in a secrets guard.** A private-identifier
  pattern blocked the repository's own GitHub URL in a badge; the fix was a
  word boundary on the pattern, not `--no-verify`. A guard that blocks
  legitimate changes trains people to bypass it.
