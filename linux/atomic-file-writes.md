# Atomic File Writes

## The problem

Writing a state file in place — open, truncate, write — has a window where the
file is only half written. A crash, OOM-kill, or full disk in that window leaves
a truncated or empty file. If the reader can't parse it and falls back to a
default (the common, well-meaning `try/except: return {}`), the corruption is
*silent*: every persisted setting is gone and nothing logged it.

## The pattern: temp + fsync + rename

```python
tmp = f"{target}.tmp"
with open(tmp, "w") as f:
    f.write(data)
    f.flush()             # Python buffer -> OS
    os.fsync(f.fileno())  # OS cache -> physical disk
os.replace(tmp, target)   # atomic rename over the target
```

Why each step:

- **Temp file in the same directory** — `rename` is only atomic *within one
  filesystem*. A temp in `/tmp` may cross a filesystem boundary and silently
  degrade to a copy, which is not atomic.
- **`flush` + `fsync`** — without fsync the rename can be persisted while the
  data is still in cache; a crash right after leaves the new name pointing at
  empty content. fsync forces the bytes down first.
- **`os.replace`** — atomic rename. A concurrent reader sees *either* the old
  complete file *or* the new complete file, never a mix. There is no truncation
  window at all.

## Shell equivalent

```bash
tmp="$(mktemp "${target}.XXXXXX")"   # same dir -> same filesystem
printf '%s' "$data" > "$tmp"
sync -f "$tmp"                        # flush the file's filesystem
mv -f "$tmp" "$target"               # mv within a fs is rename(2) = atomic
```

## When it matters

Any file another process — or a restart of the same process — reads as truth:
config, cache, lock/state, rendered templates. It matters *most* when the reader
degrades gracefully on a parse failure, because that graceful fallback is
exactly what hides the corruption.

## Transfer

- Ansible's `copy` / `template` modules write atomically for this reason (temp
  file, then move into place).
- Terraform state, etcd, and SQLite's WAL all use variants of
  write-elsewhere-then-swap.
- A plain `> file` redirect in a cron job that another service reads is the
  classic footgun.

## Related

- [Bash Scripting Patterns](bash-scripting-patterns.md)
