# Prometheus Server Configuration

## What `prometheus.yml` controls

Three things, in order of importance:

1. **Scrape configuration** — what endpoints to pull metrics from
2. **Rule files** — alert and recording rules to load
3. **Alertmanager target** — where to send firing alerts

Prometheus is intentionally simple: pull-based scraping, single-binary, no
push gateway in the default flow. The config file is the entire control surface.

## Top-level structure

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "rules/*.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "alertmanager:9093"

scrape_configs:
  - job_name: "node-vm100-storage"
    static_configs:
      - targets: ["100.x.y.z:9100"]
```

## `global`

| Setting               | Meaning                                                              |
|-----------------------|----------------------------------------------------------------------|
| `scrape_interval`     | Default frequency to pull every target. Per-job overrides allowed    |
| `evaluation_interval` | How often alert rules are evaluated against the TSDB                 |
| `scrape_timeout`      | How long to wait for a scrape response (defaults to scrape_interval) |
| `external_labels`     | Labels added to every alert before sending to Alertmanager           |

`15s` is the conventional default. Faster (5s) gives sharper graphs but doubles
storage and CPU. Slower (60s) misses short spikes. Don't change without a reason.

`evaluation_interval` should usually equal `scrape_interval` — evaluating rules
faster than data arrives wastes CPU; slower delays alerts.

## `rule_files`

```yaml
rule_files:
  - "rules/*.yml"
  - "rules/postgres/*.yml"
```

Glob patterns work. Use them — flat single-file rule sets become unmanageable
past ~20 rules. Group rules by domain (one file per service or concern):

```
rules/
  node.yml          — host-level: CPU, memory, disk, filesystem
  postgres.yml      — DB connections, replication lag, deadlocks
  snapraid.yml      — sync age, scrub age, parity errors
  smart.yml         — disk SMART status
```

Prometheus reloads rule files on `SIGHUP` or via `/-/reload` if `--web.enable-lifecycle`
is set. Without it, you must restart the binary to pick up rule changes.

## `alerting.alertmanagers`

```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "alertmanager:9093"
      timeout: 10s
      api_version: v2
```

| Setting        | Why                                                                       |
|----------------|---------------------------------------------------------------------------|
| `static_configs` | Hard-coded list. For a homelab with a single Alertmanager, this is right |
| `timeout`      | If Alertmanager is slow, drop the alert delivery rather than block scrapes |
| `api_version`  | `v2` is current. Old configs may say `v1` — upgrade                       |

Alternatives include service discovery (Consul, file-based, Kubernetes) — overkill
for static infrastructure.

## `scrape_configs` — job naming convention

```yaml
scrape_configs:
  - job_name: "node-vm100-storage"
    static_configs:
      - targets:
          - "100.x.y.z:9100"
        labels:
          host: "vm100"
          role: "storage"
```

A job-naming convention pays for itself the first time you have 30+ targets:

```
node-<id>-<role>            # node_exporter on host <id> playing role <role>
postgres-<id>               # postgres_exporter on DB host <id>
gpu-<id>                    # nvidia-smi-exporter on GPU host <id>
```

The pattern lets you grep dashboards and alert rules by structure
(`{job=~"node-.*"}`, `{job=~"postgres-.*"}`) instead of by individual hostname.

`labels:` under a target adds Prometheus labels that are attached to every
metric scraped from that target. Use them to normalize across heterogeneous
exporters: `host`, `role`, `tier`, `environment` (`prod`, `staging`, `homelab`).

## Per-job overrides

```yaml
scrape_configs:
  - job_name: "smart-exporter"
    scrape_interval: 60s              # SMART data updates slowly
    static_configs:
      - targets: ["100.x.y.z:9633"]
    metrics_path: /metrics
    scheme: http
    params:
      collect[]:
        - "smart_status"
```

| Override         | When to use                                                              |
|------------------|--------------------------------------------------------------------------|
| `scrape_interval`| Slow-changing metrics (SMART, hardware health) can scrape less often     |
| `metrics_path`   | Non-default endpoint (default: `/metrics`)                               |
| `scheme`         | `https` for secured exporters                                            |
| `params`         | Query-string parameters appended to the scrape URL                       |
| `relabel_configs`| Rewrite labels before storage. Powerful but cryptic — use sparingly      |

## Storage flags (command line, not yaml)

These are passed to the Prometheus binary, often via `command:` in compose:

```yaml
command:
  - "--config.file=/etc/prometheus/prometheus.yml"
  - "--storage.tsdb.path=/prometheus"
  - "--storage.tsdb.retention.time=90d"
  - "--web.enable-lifecycle"
```

| Flag                              | Why                                                                     |
|-----------------------------------|-------------------------------------------------------------------------|
| `--config.file`                   | Path to the YAML config (must be readable by the prometheus user)      |
| `--storage.tsdb.path`             | Where the TSDB lives. Bind-mount this to a host volume                 |
| `--storage.tsdb.retention.time`   | How long to keep samples. `15d` default is too short for capacity planning |
| `--web.enable-lifecycle`          | Enables `/-/reload` and `/-/quit` HTTP endpoints                        |
| `--web.enable-admin-api`          | Enables snapshot/delete TSDB endpoints. Don't enable without auth      |

## Reloading without restart

```bash
curl -X POST http://localhost:9090/-/reload
```

Requires `--web.enable-lifecycle`. The reload is hot — no scrape gaps, no metric
loss. If the new config has a syntax error, the reload fails and the old config
keeps running.

For CI: validate config before deploying via `promtool`:

```bash
promtool check config /etc/prometheus/prometheus.yml
promtool check rules /etc/prometheus/rules/*.yml
```

## Verification checklist

After any config change:

```bash
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job, health, scrapeUrl, lastError}'
```

Each target should report `health: "up"`. `lastError` is the first place to look
when something is `down`. Common errors:

- `connection refused` — exporter is dead or wrong port
- `EOF` — exporter crashed mid-scrape
- `no such host` — DNS issue (check MagicDNS / `/etc/hosts`)

## Related

- [PromQL & Alert Rules](promql-patterns.md)
- [Alertmanager Routing](alertmanager-routing.md)
- [Prometheus Stack Architecture](prometheus-stack.md)
