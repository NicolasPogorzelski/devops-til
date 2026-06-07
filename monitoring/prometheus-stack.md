# Prometheus Monitoring Stack

## Components

| Component | Role | Port |
|---|---|---|
| Prometheus | Metrics collection and storage | 9090 |
| Grafana | Visualization and dashboards | 3000 |
| Alertmanager | Alert routing (Discord, email) | 9093 |
| node_exporter | Host metrics (CPU, memory, disk, network) | 9100 |
| postgres_exporter | PostgreSQL metrics | 9187 |

All components bind to loopback (`127.0.0.1`) and are exposed via `tailscale serve --https`.

## How Prometheus scrapes work

Prometheus pulls metrics from targets on a schedule (default: 15s interval).
Each target exposes a `/metrics` HTTP endpoint.

```yaml
# prometheus.yml
scrape_configs:
  - job_name: node_exporter
    scrape_interval: 15s
    static_configs:
      - targets:
          - "100.x.y.z:9100"   # Tailscale IP of each node
```

Prometheus is a pull system — it reaches out to targets. Targets do not push.

## node_exporter

Deployed as a systemd binary on every managed node. Exposes ~1000 metrics about
the host: CPU utilization, memory usage, disk space, inode usage, network throughput.

```bash
# Check if running
systemctl status node_exporter

# Test metrics endpoint
curl -s http://<tailscale-ip>:9100/metrics | head -20
```

## Textfile collector pattern

For metrics that can't be scraped live (e.g. last SnapRAID sync time, last backup timestamp),
write a `.prom` file to a directory that node_exporter watches:

```bash
# node_exporter started with:
--collector.textfile.directory=/var/lib/node_exporter/textfile_collector

# Script writes:
echo "snapraid_last_sync_timestamp $(date +%s)" > /var/lib/node_exporter/textfile_collector/snapraid.prom
```

Prometheus then reads these metrics on the next scrape.

## Alert rules

Alert rules evaluate PromQL expressions on a schedule. If the condition is true
for the specified duration, the alert fires.

```yaml
- alert: NodeDown
  expr: up{job="node_exporter"} == 0
  for: 2m
  labels:
    severity: critical
  annotations:
    summary: "Node {{ $labels.instance }} is down"
```

## Key alert patterns used

| Alert | Expression | Meaning |
|---|---|---|
| `NodeDown` | `up == 0` | Target not responding to scrape |
| `DiskSpaceCritical` | `disk_free_percent < 10` | Disk nearly full |
| `HighMemoryUsage` | `mem_used_percent > 90` | Memory pressure |
| `SnapRAIDSyncStale` | `time() - last_sync > 26h` | SnapRAID hasn't synced |
| `SnapRAIDScrubStale` | `time() - last_scrub > 32d` | SnapRAID hasn't scrubbed |
| `PostgreSQLBackupStale` | `time() - last_backup > 25h` | Backup overdue |

## Node-up ≠ service-up (the monitoring blind spot)

`up == 0` from `NodeDown` only tells you the **node_exporter** target stopped
answering — i.e. the host (or its exporter) is down. It says nothing about whether the
actual application is serving traffic.

This blind spot caused a real incident (KE-8). Jellyfin (8096) and Audiobookshelf
(13378) on VM100 hung — alive as processes but not serving — while node_exporter (9100)
answered the entire time. `up{job="node-vm100-gpu"}` stayed `1`, no alert fired, and the
outage was only noticed by a human trying to use the service.

**The general rule:** node-level metrics monitor the *box*, not the *service*. A healthy
box can host a dead service. To close the gap you need a probe that speaks the service's
own protocol:

- **blackbox_exporter** — Prometheus probes an HTTP(S)/TCP endpoint from the outside and
  exports whether it responded, the status code, and latency. A `ServiceDown` rule on a
  failed HTTP probe catches "port open but app wedged" and "port dead" alike.

```yaml
# sketch of the intended remediation (not yet deployed here)
- alert: ServiceDown
  expr: probe_success{job="blackbox-http"} == 0
  for: 2m
  labels: { severity: critical }
  annotations:
    summary: "Service {{ $labels.instance }} failing HTTP probe"
```

`probe_success` comes from blackbox_exporter, not node_exporter — that is the whole
point: a *second, independent* signal at the application layer.

## Using `up` to bound an incident after the fact

A debugging trick from the same investigation: the `up` metric is a per-scrape
historical record, so you can prove what the node was doing during a past window even
when application logs are gone.

```promql
# count successful scrapes in the incident window (expect ~one per scrape_interval)
count_over_time(up{job="node-vm100-gpu"}[2h])

# was the node ever actually down in the window?
min_over_time(up{job="node-vm100-gpu"}[2h])
```

- `count_over_time(...[2h])` — number of samples in the range. 300/300 expected samples
  present meant the node never stopped being scraped — it was reachable throughout.
- `min_over_time(...[2h])` — if this is `1`, `up` was never `0`; the node never went
  down. A single 60s gap lined up exactly with the recovery restart, nothing else.

This is how the KE-8 investigation *excluded* "node down / network loss" as causes
without any application log to lean on — Prometheus retained the evidence the journal
didn't (see [systemd Basics → Persistent journald storage](../linux/systemd-basics.md)).

## Alertmanager routing

Alertmanager receives fired alerts from Prometheus and routes them to receivers.

```yaml
route:
  receiver: discord
receivers:
  - name: discord
    discord_configs:
      - webhook_url: <discord-webhook-url>
```

## Staleness detection pattern

For jobs that run periodically (cron, backup scripts), write a Unix timestamp
on success. Alert if the timestamp is too old:

```promql
time() - my_job_last_success_timestamp > 86400   # more than 24h ago
```

This is more reliable than checking if a process is running — it catches
silent failures where the job runs but does nothing.

## Related

- [Operations: Runbook Methodology](../operations/runbook-methodology.md)
