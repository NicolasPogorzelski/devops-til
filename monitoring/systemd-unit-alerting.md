# Alerting on Failed systemd Units - and Why the First Alert Is Good News

## The blind spot

A monitoring stack can look complete and still miss the most common failure mode there is.
Mine covered:

- `NodeDown` - is the machine up? (node_exporter scrape)
- disk fill - is there space left?
- `ServiceDown` - do the HTTP endpoints answer? (blackbox probes)

A **systemd unit in `failed` state fits none of those.** The node is up, the disk is fine, the web
UI answers. A timer-driven import job failed every two minutes for a month behind a green
dashboard - roughly 20,000 failures, zero alerts.

## The fix, in three parts

**1. Export the state.** `node_exporter` does not collect systemd metrics by default:

```
ExecStart=/usr/local/bin/node_exporter \
  --collector.systemd \
  --collector.systemd.unit-exclude='.+\.(automount|device|scope|slice)'
```

The exclude regex matters: the **stock exclude drops `.mount` units**, and mount units are exactly
where network-storage failures land. Excluding `automount|device|scope|slice` keeps `.service`,
`.mount` and `.timer` in scope - the three that can represent a real fault.

Escaping trap: systemd applies C-style escaping to `ExecStart=` arguments, and `\.` is not a
sequence it knows. Write `\\.` in the unit file to emit a literal backslash, or
`systemd-analyze verify` warns about unknown escape sequences and you are relying on undefined
fallback behaviour.

**2. Alert on it.**

```yaml
- alert: SystemdUnitFailed
  expr: node_systemd_unit_state{state="failed"} == 1
  for: 15m
  labels: { severity: warning }
```

`for: 15m` absorbs the transient failures of the boot window - a unit that fails once while the
network comes up and then succeeds never pages.

**3. No exception list. Ever.** The temptation is `expr: ... unless name=~"openipmi|foo"`. Don't.
A unit that can never succeed on a node is removed or masked **at the source**; the moment the
alert rule grows an ignore-list, it starts hiding things, and nobody re-reads an ignore-list.

## What happens when you switch it on

Within three hours of enabling `--collector.systemd` on a hypervisor that had never exported it:

```
[FIRING] SystemdUnitFailed  openipmi.service  node-proxmox-host
```

`openipmi.service` had been failing at **every boot for 53 boots - 141 failures**. The machine has
no BMC; the unit could never succeed. It had simply never been visible.

**That alert is not a regression. It is the proof the chain works:**

```
unit fails -> node_exporter exports state="failed" 1 -> Prometheus scrapes -> rule fires
```

Expect this. When you add a collector to a machine that never had one, the first alerts are
archaeology, not news. Triage them, fix the causes at the source, and the noise floor returns to
zero - this host now reports **no failed units at all**.

## Prove the chain, including the negative case

The unit I *replaced* passed its positive test for months while doing nothing (it ended in
`|| true`). So test failure, not success:

```bash
# make the thing fail on purpose
mkdir /mnt/smb/zz-test
systemctl restart smb-mounts-check.service        # expect: failed, exit 1

# does the failure actually leave the machine?
curl -s localhost:9100/metrics | grep 'state="failed"} 1'
# node_systemd_unit_state{name="smb-mounts-check.service",state="failed",type="oneshot"} 1

# clean up, confirm it returns to 0
rmdir /mnt/smb/zz-test
systemctl reset-failed smb-mounts-check.service && systemctl start smb-mounts-check.service
```

A guard you have not seen fail is not a guard. It is a decoration.

## Design consequence: write jobs that *can* fail

Alerting on failed units only pays off if your scripts actually exit non-zero when something is
wrong. The two habits that kill it:

- `... || true` at the end of a check - the unit always succeeds.
- `exit 0` on "the storage isn't there, that's fine" - the polite no-op that hides a month of
  outage. Let it exit 1 and let `for: 15m` absorb the transient case.

## Coverage gaps to check on your own fleet

- **Containerised node_exporter cannot see the host's systemd.** A node_exporter running as a
  Docker container has no access to the host's D-Bus/systemd, so `--collector.systemd` yields
  nothing. My monitoring node is exactly this, and is therefore the one node with no unit-failure
  coverage - the monitor being the blind spot is a classic.
- **The hypervisor is a node too.** It was excluded from the fleet's config management, so nobody
  noticed it exported no systemd metrics for months.

## Related

- [Prometheus Config](prometheus-config.md)
- [PromQL Patterns](promql-patterns.md)
- [CIFS Automount](../storage/cifs-automount.md) - the failure this was built for
- [apt & dpkg](../linux/apt-dpkg.md) - the package residue the first alert uncovered
