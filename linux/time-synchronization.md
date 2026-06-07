# Time Synchronization (chrony, NTP, timedatectl)

A wrong clock is a silent failure. Nothing crashes — but timestamp-based logic
quietly produces wrong answers. This bit a storage node in this homelab: VM102
had no time daemon at all, drifting on the hardware clock alone.

## Two clocks, one problem

A Linux box has two clocks:

| Clock | What it is | Persists across reboot? |
|---|---|---|
| **System clock** | Maintained by the kernel in RAM while running | No |
| **RTC (hardware clock)** | Battery-backed chip on the board (or emulated by the hypervisor for a VM) | Yes |

At boot the system clock is seeded from the RTC, then the kernel keeps it ticking.
Both drift — a few seconds to minutes per day — because crystal oscillators aren't
perfectly accurate and temperature changes the rate. **NTP** (Network Time Protocol)
corrects the system clock continuously by comparing it against remote time servers
and steering it (speeding up / slowing down) back toward true time.

Without an NTP client running, nothing corrects the drift. The clock is only ever as
good as the RTC, and it slowly walks away from reality.

## Inspect first: `timedatectl`

```bash
timedatectl
```

Key lines in the output:

| Line | Meaning |
|---|---|
| `Local time` / `Universal time` | Current system clock (local TZ and UTC) |
| `RTC time` | The hardware clock's value |
| `System clock synchronized: yes/no` | Has an NTP source actually disciplined the clock? |
| `NTP service: active / inactive / n/a` | Is a time daemon running? `n/a` = none installed |

The failure signature on VM102 before the fix was `NTP service: n/a` +
`System clock synchronized: no` — i.e. no daemon was installed at all, so the clock
relied on RTC/hypervisor only and drifted.

## The daemon: chrony

Debian ships three common implementations; pick one — they conflict if more than one
runs:

| Implementation | Notes |
|---|---|
| `systemd-timesyncd` | Lightweight SNTP client, built into systemd. Good enough for laptops/desktops. Client-only (can't serve time). |
| `chrony` | Full NTP implementation. Handles intermittent connectivity and large initial offsets better; can also serve time to other hosts. **Chosen here.** |
| `ntp` (classic `ntpd`) | The original reference daemon. Largely superseded by chrony on modern Debian. |

`chrony` is the better default for a server that may be offline for stretches: it can
step the clock quickly on startup and slew gently afterward, and it recovers cleanly
from a dead network link.

### Install (Debian 12)

```bash
apt-get install -y chrony
systemctl enable --now chrony
```

- `apt-get install -y chrony` — `-y` auto-confirms; the package ships a working
  default config (`/etc/chrony/chrony.conf`) pointing at the Debian NTP pool.
- `systemctl enable --now chrony` — `enable` adds the boot symlink so it survives
  reboot; `--now` also starts it immediately (combines `enable` + `start`).

> On VM102 this was done **ad-hoc via Ansible** (`ansible vm102 -m apt ...`). A
> dedicated fleet-wide `chrony` role is still pending — codifying ad-hoc fixes into
> roles is the standing follow-up.

### Verify

```bash
chronyc tracking     # is the clock disciplined, and by how much?
chronyc sources      # which servers, and which one is selected (^*)
timedatectl          # System clock synchronized: should now read yes
```

- `chronyc tracking` — shows the reference server, the current offset, and the drift
  rate chrony is correcting. `System time : 0.0000xx seconds slow/fast of NTP time`
  near zero means it's locked on.
- `chronyc sources` — one row per configured server; the `^*` marker is the currently
  selected synchronization source, `^+` are acceptable alternates, `^?` unreachable.

After the fix, `timedatectl` reported `System clock synchronized: yes`.

## Why a wrong clock actually hurt this setup

The lesson isn't "NTP is good hygiene" in the abstract — on a storage node a drifting
clock breaks real logic:

- **SnapRAID change detection** is timestamp + size based. SnapRAID decides a file
  changed by comparing mtime and size. A clock that jumps around makes that signal
  unreliable.
- **`SnapRAIDSyncStale` alert math** is `time() - last_sync_timestamp > 26h`. If the
  node writes a wrong `last_sync` timestamp, the staleness window is computed against
  a lie — the alert can fire late or not at all (see
  [PromQL & Alert Rules](../monitoring/promql-patterns.md)).
- **Cross-node log correlation** during an incident depends on clocks agreeing. If
  VM102's logs are minutes off from VM100's, reconstructing a timeline across nodes
  becomes guesswork — which is exactly what hurt during the KE-8 investigation
  ([Prometheus Stack](../monitoring/prometheus-stack.md)).

## LXC vs VM: who needs a time daemon?

A subtle Proxmox point: **unprivileged LXCs do not run their own time daemon.** A
container shares the host kernel, and the kernel owns the clock — so an LXC inherits
the Proxmox host's (synchronized) time. Running chrony *inside* an LXC is pointless
(and it can't set the clock anyway without `CAP_SYS_TIME`).

**VMs are different.** A VM has its own kernel and its own (emulated) RTC, so it needs
its own time discipline — either a guest time daemon (chrony) or hypervisor-driven
sync via the guest agent. In this homelab VM100 was already synced; VM102 was the gap.

So the rule of thumb here:

| Guest type | Needs its own NTP daemon? |
|---|---|
| LXC (unprivileged) | No — inherits the Proxmox host clock |
| VM | Yes — own kernel, own RTC, must discipline itself |

## Related

- [SnapRAID + MergerFS](../storage/snapraid-mergerfs.md)
- [PromQL & Alert Rules](../monitoring/promql-patterns.md)
- [systemd Basics](systemd-basics.md)
- [Proxmox: LXC & VM Management](../proxmox/lxc-vm-management.md)
