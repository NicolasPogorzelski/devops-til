# Alertmanager Routing & Notification

## What Alertmanager does (and doesn't)

Alertmanager is a **deduplication, grouping, and routing** layer. It does not
generate alerts — Prometheus does. It does not store metrics — Prometheus does.
It receives firing alerts and decides:

1. Should I send a notification at all? (silences, inhibits)
2. If yes, group it with related ones?
3. Where do I send it? (Slack, Discord, email, PagerDuty)
4. When do I notify again if it's still firing? (`repeat_interval`)

Splitting Prometheus and Alertmanager seems redundant for a homelab but is the
right architecture: Prometheus reloads do not lose pending notifications, and
Alertmanager redundancy is independent of metric collection.

## Top-level structure

```yaml
global:
  resolve_timeout: 5m

route:
  receiver: "default"
  group_by: ["alertname", "instance"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  routes:
    - matchers:
        - severity = "critical"
      receiver: "discord-critical"
    - matchers:
        - severity = "warning"
      receiver: "discord-warning"

receivers:
  - name: "default"
    discord_configs:
      - webhook_url: "${DISCORD_WEBHOOK}"
  - name: "discord-critical"
    discord_configs:
      - webhook_url: "${DISCORD_CRITICAL_WEBHOOK}"
  - name: "discord-warning"
    discord_configs:
      - webhook_url: "${DISCORD_WEBHOOK}"

inhibit_rules:
  - source_matchers: [severity = "critical"]
    target_matchers: [severity = "warning"]
    equal: ["alertname", "instance"]
```

## The four time settings — and why each exists

| Setting              | What it controls                                            | Typical homelab value |
|----------------------|-------------------------------------------------------------|------------------------|
| `group_wait`         | Wait this long after first alert in a group before notifying | `30s`                  |
| `group_interval`     | After first notification, wait this long before sending updates for new alerts in the same group | `5m` |
| `repeat_interval`    | Re-send the same alert if still firing after this long       | `12h`                  |
| `resolve_timeout`    | An alert is "resolved" if not received again within this time | `5m`                   |

`group_wait` exists because alerts often arrive in clusters: a server going down
fires `HostDown`, `NodeExporterDown`, `SSHDown` within seconds. Without `group_wait`,
each becomes a separate notification. With `group_wait: 30s`, the first one waits,
catches the others, and you get one consolidated message.

`repeat_interval` is what stops Alertmanager from spamming you. `12h` is the
sweet spot for a homelab — you'll see the alert at start of day if it persists,
without getting paged every hour overnight. For 24/7 production, `4h` or shorter.

## `group_by` — what defines a "group"

```yaml
group_by: ["alertname", "instance"]
```

Alerts sharing all listed label values are grouped into one notification.

| `group_by` value             | Effect                                                    |
|------------------------------|-----------------------------------------------------------|
| `["alertname"]`              | All instances of one alert type collapse into one message |
| `["alertname", "instance"]`  | Per-host: one message per (alertname, host) pair          |
| `["..."]` (literal `...`)    | Group all alerts together (single notification per round) |
| `[]` (empty)                 | No grouping — every alert is its own notification         |

For most homelabs, `["alertname", "instance"]` is right: a disk-full alert on
two different hosts shouldn't be merged, but multiple firings of the same alert
on the same host should be.

## Inhibit rules — preventing redundant noise

When a critical alert fires, you usually don't want the warning that preceded
it to keep notifying you separately:

```yaml
inhibit_rules:
  - source_matchers: [severity = "critical"]
    target_matchers: [severity = "warning"]
    equal: ["alertname", "instance"]
```

| Field              | Meaning                                                                |
|--------------------|------------------------------------------------------------------------|
| `source_matchers`  | If an alert matching these is firing...                                |
| `target_matchers`  | ...suppress notifications for alerts matching these...                 |
| `equal`            | ...where these labels are equal between source and target              |

The `equal` clause is critical: without it, a critical alert *anywhere* would
suppress all warnings *anywhere*. With `equal: ["alertname", "instance"]`,
suppression is scoped: a `HostDiskCritical` on `vm100` suppresses
`HostDiskWarning` on `vm100` only.

## Routing tree — first match wins

```yaml
route:
  receiver: "default"      # fallback
  routes:
    - matchers: [severity = "critical"]
      receiver: "pager"
    - matchers: [team = "storage"]
      receiver: "storage-team-discord"
    - matchers: [severity = "warning"]
      receiver: "low-priority-channel"
```

Alertmanager walks the routes top-down and uses the **first match**. Order matters:

- A storage-team **critical** alert: matches the first route (`severity = critical`),
  goes to `pager`. The `team = storage` route is *not* checked.
- A storage-team **warning**: doesn't match `critical`, matches `team = storage`,
  goes to `storage-team-discord`.

If you want a warning storage alert to go to *both* the team channel and the
warning channel: set `continue: true` on the matching route, which lets evaluation
fall through to subsequent routes.

## Receivers — Discord webhook

Alertmanager 0.27+ has native Discord support:

```yaml
receivers:
  - name: "discord-critical"
    discord_configs:
      - webhook_url_file: /etc/alertmanager/secrets/discord-critical-url
        title: "🚨 {{ .GroupLabels.alertname }}"
        message: |
          {{ range .Alerts }}
          **{{ .Labels.instance }}**: {{ .Annotations.summary }}
          {{ end }}
```

| Setting          | Why                                                                          |
|------------------|------------------------------------------------------------------------------|
| `webhook_url_file` | Read URL from file. Better than `webhook_url:` directly — keeps secrets out of YAML |
| `title`            | Discord embed title. Templated like Prometheus annotations                  |
| `message`          | Body of the message. The `range .Alerts` iterates all alerts in the group   |

For old Alertmanager versions without native Discord support, use the generic
`webhook_configs` and let Discord's webhook URL do the formatting (limited).

## Silences — for planned maintenance

A silence suppresses alerts matching a label set for a duration:

```bash
amtool silence add severity=warning instance=vm100 \
  --duration=2h --comment="planned reboot" --author="nicolas"
```

| Flag           | Why                                                                       |
|----------------|---------------------------------------------------------------------------|
| `--duration`   | Auto-expires. Forgotten silences are how alerts get missed for years       |
| `--comment`    | Required by `amtool` — forces you to document the reason                  |
| `--author`     | Who silenced it. Audit trail                                              |

Silences are stored in Alertmanager's local storage and survive restarts.
They can also be created via the web UI at `:9093`.

## Reload without restart

```bash
curl -X POST http://localhost:9093/-/reload
```

Same pattern as Prometheus. Validate first:

```bash
amtool check-config /etc/alertmanager/alertmanager.yml
```

## Related

- [PromQL Patterns](promql-patterns.md)
- [Prometheus Configuration](prometheus-config.md)
