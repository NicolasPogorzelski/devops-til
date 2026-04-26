# Paperless-ngx Deployment

## What Paperless-ngx is

A document management system for scanned PDFs and images: it ingests files from
a "consume" folder, runs OCR, classifies them by tags/correspondents, and exposes
them through a web UI with full-text search.

Architecture is a multi-container pipeline:

```
       File drops in consume/
                │
                ▼
        ┌───────────────┐    OCR via tesseract
        │ paperless-ngx │◄────────────────────
        │  (Django app) │
        └──────┬────────┘
               │
   ┌───────────┼─────────────────────┐
   ▼           ▼                     ▼
┌─────────┐ ┌──────────┐      ┌─────────────┐
│ Redis   │ │ Postgres │      │ Gotenberg   │
│ (queue) │ │ (state)  │      │ (Office→PDF)│
└─────────┘ └──────────┘      └─────────────┘
                                     │
                                     ▼
                              ┌─────────────┐
                              │ Apache Tika │
                              │ (metadata)  │
                              └─────────────┘
```

| Component   | Role                                                                         |
|-------------|------------------------------------------------------------------------------|
| Paperless   | Django web app + Celery workers                                              |
| Redis       | Celery broker + cache. Required.                                             |
| PostgreSQL  | State (documents, tags, users). MariaDB and SQLite also work.                |
| Gotenberg   | Headless Chromium for converting Office docs to PDF                          |
| Apache Tika | Metadata extraction from non-PDF formats (Word, Excel, etc.)                 |

You can run without Gotenberg + Tika; you lose Office-document ingestion in exchange.

## Hardening Gotenberg

Gotenberg ships a headless Chromium. By default it allows JavaScript execution
when converting HTML → PDF. For a document-management context, JS in arriving
files is a vulnerability surface, not a feature.

```yaml
gotenberg:
  image: gotenberg/gotenberg:8
  command:
    - "gotenberg"
    - "--chromium-disable-javascript=true"
    - "--chromium-allow-list=file:///tmp/.*"
```

| Flag                                  | Why                                                                  |
|---------------------------------------|----------------------------------------------------------------------|
| `--chromium-disable-javascript=true`  | Documents being converted cannot execute scripts                     |
| `--chromium-allow-list=file:///tmp/.*`| Restricts which URLs Chromium will load — local files only           |

Without the disable-javascript flag, a maliciously-crafted HTML file in your
inbox could perform requests when Gotenberg renders it.

## CSRF — `PAPERLESS_CSRF_TRUSTED_ORIGINS`

Django enforces same-origin POST requests via CSRF tokens. When Paperless is
served from a hostname different from `localhost` (e.g., a Tailscale MagicDNS
hostname), POST requests fail with `403 CSRF verification failed`.

```yaml
environment:
  PAPERLESS_URL: "https://paperless.tail-xxxx.ts.net"
  PAPERLESS_CSRF_TRUSTED_ORIGINS: "https://paperless.tail-xxxx.ts.net"
```

| Variable                          | Purpose                                                             |
|-----------------------------------|---------------------------------------------------------------------|
| `PAPERLESS_URL`                   | Used for generating absolute URLs (email links, share links)        |
| `PAPERLESS_CSRF_TRUSTED_ORIGINS`  | Comma-separated list of origins allowed to POST                     |

Both must include the scheme (`https://`). Multiple origins are comma-separated
without spaces. Don't use a wildcard — it defeats CSRF protection.

## OCR language

```yaml
PAPERLESS_OCR_LANGUAGE: "deu+eng"
```

Tesseract takes language codes in `lang1+lang2` form. The `+` joins them — both
languages are tried and the higher-confidence match wins per page. For mixed
German/English documents, `deu+eng` (or `eng+deu`) gives noticeably better
results than either alone.

Trade-off: each added language increases OCR time roughly proportionally. Don't
list every language "just in case" — only those you actually have documents in.

The language pack must be installed in the container. The official image ships
with a configurable list; check `PAPERLESS_OCR_LANGUAGES` (plural) for build-time
inclusion if you need a non-default language.

## USERMAP_UID / USERMAP_GID

linuxserver-style images use `PUID`/`PGID` env vars to make the container
process run as a specific UID:GID. The Paperless image uses
`USERMAP_UID`/`USERMAP_GID` (different name, same idea):

```yaml
environment:
  USERMAP_UID: 1000
  USERMAP_GID: 1000
```

| Variable      | What it does                                                              |
|---------------|---------------------------------------------------------------------------|
| `USERMAP_UID` | Container's runtime user is mapped to this host UID                       |
| `USERMAP_GID` | Same for GID                                                              |

Why this matters: bind-mounted directories (the consume folder, media folder,
data folder) on the host are owned by some UID. If the container process runs as
a different UID, it cannot write — or worse, files it creates are owned by an
unexpected UID and become unreadable from the host side.

For unprivileged LXC containers, the *host* UID is shifted (e.g., +100000), so
USERMAP_UID=1000 inside the container means the bind-mount must be owned by
UID 101000 on the Proxmox host. Document this mapping per service.

## inotify doesn't work on CIFS — use polling

Paperless watches its consume directory for new files. By default it uses
**inotify** (Linux's filesystem-event API). That works on local filesystems and
ext4, but **not on CIFS/SMB mounts** — inotify events are not propagated across
the network protocol.

```yaml
environment:
  PAPERLESS_CONSUMER_POLLING: "30"
```

| Variable                       | What it does                                                  |
|--------------------------------|---------------------------------------------------------------|
| `PAPERLESS_CONSUMER_POLLING`   | Poll the consume directory every N seconds instead of inotify |

`30` is a reasonable compromise: documents appear within 30s of arrival but the
filesystem isn't being hammered with constant `readdir()` calls. Set lower (5s)
for impatient workflows, higher (300s) for nightly batch ingestion.

This is a general lesson: **any filesystem-event-driven tool needs a polling
fallback for network filesystems**. NFS has a partial inotify implementation,
SMB has none.

## Workflows with wildcard path matching

Paperless v2.20+ supports workflows that trigger on path patterns:

```
trigger:
  type: consumption
  source: folder
  path: "*Nico*"
```

The pattern is shell-glob: `*` matches any sequence, `?` matches one character,
`[abc]` matches a character class. Useful for routing documents arriving in
different subfolders to different tags/correspondents automatically.

## File deletion behavior after consumption

Once Paperless has consumed a file (OCR'd it, stored it in its archive), the
file is **deleted** from the consume folder. Empty subdirectories are also
removed. This is by design — the consume folder is a queue, not a permanent
location.

Architectural consequence: don't put a `*.pdf` in the consume folder for "safekeeping".
If you want a file *and* an entry in Paperless, copy the file elsewhere first.

## Related

- [PostgreSQL Operations](../database/postgresql-ops.md)
- [CIFS Automount](../storage/cifs-automount.md)
- [Docker Compose Patterns](../docker/compose-patterns.md)
