# Nextcloud Administration (`occ` CLI)

## What `occ` is

`occ` (ownCloud Console - the project's historical name) is Nextcloud's admin CLI.
It lives at `<webroot>/occ` and must be run as the web-server user (the user
that owns the Nextcloud files), because it writes to the same files PHP-FPM/Apache do.

```bash
sudo -u www-data php /var/www/nextcloud/occ <command>
```

| Part                                | Why                                                     |
|-------------------------------------|---------------------------------------------------------|
| `sudo -u www-data`                  | Run as web-server user - same UID that owns the files   |
| `php`                               | `occ` is a PHP script invoked via the PHP CLI           |
| `/var/www/nextcloud/occ`            | Path to the script (varies by install method)           |

Running `occ` as root works in some installs but breaks file permissions on any
file the command writes (config, logs, cache). Always use `sudo -u <web-user>`.

## Architecture: Apache + PHP-FPM + MariaDB + Redis

A non-Docker Nextcloud install on Debian:

```
                             ┌─────────────────┐
        Client (HTTPS) ───>  │ Apache (TLS)    │
                             │ /var/lib/tail-  │
                             │  scale/certs    │
                             └────────┬────────┘
                                      │ FastCGI (Unix socket)
                                      v
                             ┌─────────────────┐
                             │ PHP-FPM         │
                             │ (www-data)      │
                             └────────┬────────┘
                                      │
                ┌─────────────────────┼─────────────────────┐
                v                     v                     v
        ┌────────────┐         ┌────────────┐         ┌────────────┐
        │ MariaDB    │         │ Redis      │         │ Filesystem │
        │ (state)    │         │ (locking)  │         │ (data dir) │
        └────────────┘         └────────────┘         └────────────┘
```

Why each piece:

- **MariaDB** for relational state (users, shares, file index). `dbhost=localhost`
  for a same-host install to use the Unix socket - faster and removes one network hop.
- **Redis** for **distributed file locking** (`OC\Memcache\Redis` for `memcache.locking`)
  and **transactional cache** (`memcache.distributed`).
- **APCu** for **local cache** (`memcache.local`) - in-process PHP cache, fast
  but not shared between PHP workers.

The cache split is important: APCu is per-process, Redis is shared. Using only
one or the other gives you either too-slow cache or unnecessarily-shared cache.
The Nextcloud docs explicitly recommend "APCu local + Redis distributed/locking".

## TLS via Tailscale-managed certs

Tailscale can issue Let's Encrypt certs for MagicDNS hostnames and store them at
`/var/lib/tailscale/certs/<hostname>.<tailnet-id>.ts.net.{crt,key}`.

Apache config:

```apache
SSLEngine on
SSLCertificateFile      /var/lib/tailscale/certs/nextcloud.<tailnet-id>.ts.net.crt
SSLCertificateKeyFile   /var/lib/tailscale/certs/nextcloud.<tailnet-id>.ts.net.key
```

Renewal: `tailscale cert <hostname>` re-issues; cron it weekly. The cert is
only valid inside the Tailnet (the cert hostname resolves only via MagicDNS),
which is fine because that's the only place clients connect from.

This is an alternative to the loopback + `tailscale serve` pattern (see
[Loopback Tailscale Serve](../networking/loopback-tailscale-serve.md)).
For Nextcloud specifically, direct Apache TLS is preferred because:

- Multi-GB uploads benefit from full LAN speed (no Tailscale Serve proxy hop)
- Apache handles TLS efficiently for large request bodies
- Nextcloud's WebDAV chunked uploads need stable long-lived connections

## Common `occ` commands

### File scanning

When files appear on the filesystem (e.g., dropped via Samba into the data dir)
without going through the Nextcloud API, the database doesn't know about them.
`files:scan` reconciles the DB with the filesystem.

```bash
sudo -u www-data php occ files:scan --all
sudo -u www-data php occ files:scan <username>
sudo -u www-data php occ files:scan --path="<username>/files/Inbox"
```

| Flag           | Effect                                                                  |
|----------------|-------------------------------------------------------------------------|
| `--all`        | Scan every user. Slow on large installs.                                |
| `<username>`   | Positional: scan only this user's storage                               |
| `--path=...`   | Scan only this subpath. Fast - use this for "I just dropped a file in X" |

### External storage

`files_external` is the Nextcloud app for mounting external sources (SMB, S3, etc.)
into a user's view. Operations:

```bash
sudo -u www-data php occ files_external:list                         # show all configured mounts
sudo -u www-data php occ files_external:verify <mount-id>            # test a mount
sudo -u www-data php occ files_external:applicable <mount-id>        # who has access
sudo -u www-data php occ files_external:applicable --add-user=<user> <mount-id>
```

| Command                           | Use case                                                  |
|-----------------------------------|-----------------------------------------------------------|
| `files_external:verify`           | "Why can't user X see the share?" - first thing to run    |
| `files_external:applicable`       | Audit who has access to a given external mount            |

### User listing for scripts

```bash
sudo -u www-data php occ user:list --output=json
```

`--output=json` makes the output parseable. For shell scripts that need to iterate
over users, this is the right form. Combine with `jq` or a small PHP one-liner
for parsing.

## Running `occ` from a cron script

A script run as root can dispatch to `www-data`:

```bash
su -s /bin/bash -c 'php /var/www/nextcloud/occ files:scan --path="alice/files/Inbox"' www-data
```

| Part                    | Why                                                              |
|-------------------------|------------------------------------------------------------------|
| `su -s /bin/bash`       | Use bash explicitly - `www-data`'s default shell may be `nologin` |
| `-c '<command>'`        | Run this command non-interactively                               |
| `www-data`              | Target user                                                      |

`sudo -u www-data` works equivalently; `su -s` is just the older form, often
seen in cron scripts because it has no `sudo` dependency.

## Related

- [PostgreSQL CLI Operations](../database/postgresql-cli.md) (related shell admin)
- [Loopback Tailscale Serve](../networking/loopback-tailscale-serve.md)
- [CIFS Automount](../storage/cifs-automount.md)
