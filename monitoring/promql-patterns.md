# PromQL & Alert Rule Patterns

## Anatomy of an alert rule

```yaml
groups:
  - name: node
    rules:
      - alert: HostDiskSpaceLow
        expr: |
          (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.lxcfs"} /
           node_filesystem_size_bytes) * 100 < 10
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} filesystem {{ $labels.mountpoint }} below 10%"
          description: "Available: {{ printf \"%.1f\" $value }}%"
```

Five parts:

| Part           | Role                                                                   |
|----------------|------------------------------------------------------------------------|
| `alert:`       | Alert name. Used for routing in Alertmanager                          |
| `expr:`        | PromQL. Boolean - alert fires when this returns a non-empty result    |
| `for:`         | Debounce - must remain true continuously for this duration            |
| `labels:`      | Metadata attached to firing alerts. Used for routing                  |
| `annotations:` | Human-readable text. Templates can reference `$labels` and `$value`   |

## `for:` - the debouncing tool

`for: 10m` means "the expression must be continuously true for 10 minutes
before the alert fires". This is the single most important alerting setting.

| Use case                              | `for:` value | Reasoning                                  |
|---------------------------------------|--------------|--------------------------------------------|
| Disk full, growing slowly             | `30m`        | Plenty of time to react, no false alarms   |
| Service hard down                     | `2m`         | Want to know fast; allows for restart blip |
| CPU 100%                              | `15m`        | Brief spikes are normal                    |
| Backup did not run last night         | `0` (no for) | Already a daily-aggregated check            |

Without `for:`, every momentary blip generates a notification. With too long a
`for:`, real failures take ages to alert. Default to `2m` for binary up/down,
`10-15m` for resource pressure.

## Labels: severity convention

Two values, no third:

| `severity:` | Meaning                                                        |
|-------------|----------------------------------------------------------------|
| `critical`  | User-affecting now. Wake someone up.                           |
| `warning`   | Trending toward problem; investigate during business hours     |

Adding `info` or `notice` levels is a common mistake - alerts at "info" level
get ignored. If something is informational, it goes in a dashboard, not an alert.

`severity` is what Alertmanager routes on. See [Alertmanager Routing](alertmanager-routing.md).

## Filesystem queries - excluding pseudo-filesystems

Naive `node_filesystem_avail_bytes` includes tmpfs, overlayfs, fuse mounts.
Filtering them out is non-optional:

```promql
node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.lxcfs|overlay"}
```

| Operator | Meaning                          |
|----------|----------------------------------|
| `=`      | Exact match                      |
| `!=`     | Not equal                        |
| `=~`     | Regex match                      |
| `!~`     | Regex not match                  |

`fstype!~"tmpfs|fuse.lxcfs|overlay"` reads as "fstype does not match the regex
`tmpfs|fuse.lxcfs|overlay`". Without it, every tmpfs near-fullness (which is
normal - tmpfs grows on demand) generates noise.

Add the same filter to disk-related alerts:

```promql
node_filesystem_size_bytes{fstype!~"tmpfs|fuse.lxcfs|overlay"}
```

## Aggregation: `sum by`

Multiple time series can be reduced to one per group:

```promql
sum by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
```

| Pattern              | What it does                                              |
|----------------------|-----------------------------------------------------------|
| `sum by (instance)`  | Sum across everything else, keeping `instance` as label   |
| `sum without (cpu)`  | Sum across `cpu`, keep all other labels                   |
| `avg by (instance)`  | Average instead of sum                                    |

`without` is often clearer than `by` when most labels should be preserved.
`by (instance)` collapses everything except instance.

## PostgreSQL filtering - exclude internal databases

```promql
pg_stat_activity_count{datname!~"template.*|postgres"}
```

System databases (`template0`, `template1`, `postgres`) always have at least
one connection (autovacuum). Without filtering, your "DB has too many connections"
alert never goes below 3, regardless of application activity.

Same pattern applies to:

- User filtering: `{usename!="postgres"}` to exclude maintenance user
- Schema filtering: `{schemaname!~"pg_.*|information_schema"}`

## Annotation templating

```yaml
annotations:
  summary: "{{ $labels.instance }} {{ $labels.mountpoint }}: {{ printf \"%.1f\" $value }}%"
```

| Template var       | Resolves to                                              |
|--------------------|----------------------------------------------------------|
| `{{ $labels.X }}`  | Value of label `X` on the firing series                  |
| `{{ $value }}`     | Numeric value of the alert expression                    |

`printf "%.1f"` formats to one decimal place. Without it, you get `9.731289326`
in your alert text - readable, but not pretty. Common formats:

| Format     | Example output                          |
|------------|-----------------------------------------|
| `%.0f`     | `42`                                    |
| `%.1f`     | `42.3`                                  |
| `%.2f`     | `42.31`                                 |
| `%g`       | `42.3142` (auto-trims trailing zeros)   |

## Annotations vs labels - what's the difference

| Field           | Used by                                               |
|-----------------|-------------------------------------------------------|
| **labels**      | Alertmanager for routing/grouping. Affect alert identity |
| **annotations** | Humans. Display text. Do not affect routing            |

Putting `summary` in labels is wrong - Alertmanager would treat every distinct
summary as a different alert and never group them. Putting `severity` in
annotations is wrong - routes can't reach it.

Rule of thumb: **label = identifier or routing dimension. Annotation = description**.

## Group-by-domain rule files

```yaml
groups:
  - name: snapraid           # one group per domain
    interval: 5m             # less frequent eval - these are slow-moving
    rules:
      - alert: SnapraidSyncOverdue
        expr: time() - snapraid_last_sync_seconds > 86400 * 2
        for: 0
        labels: { severity: warning }
        annotations:
          summary: "snapraid sync hasn't run in {{ printf \"%.0f\" $value }}s"
```

Per-group `interval:` overrides the global `evaluation_interval`. Slow-moving
domains (storage health, backup ages) don't need to be evaluated every 15s.

## Recording rules - pre-computing expensive queries

When a dashboard query is slow because PromQL evaluates over millions of samples,
move the work to a *recording rule* that pre-computes the value periodically:

```yaml
groups:
  - name: aggregations
    interval: 1m
    rules:
      - record: instance:node_cpu_utilization:rate5m
        expr: |
          1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
```

Naming convention: `<aggregation_level>:<metric>:<operation>`. The dashboard
then queries `instance:node_cpu_utilization:rate5m` directly - pre-computed,
fast, and consistently named across dashboards.

## Validation

```bash
promtool check rules /etc/prometheus/rules/*.yml
promtool test rules /etc/prometheus/rules/test/*.yml
```

`check` validates syntax. `test` runs unit tests defined in test YAML files -
overkill for homelab, essential at scale.

## Related

- [Prometheus Configuration](prometheus-config.md)
- [Alertmanager Routing](alertmanager-routing.md)
