# Diagnosing a Frozen VM (guest hard-freeze)

A VM can be **hard-frozen inside the guest** while the hypervisor still reports it as
`running`. The whole diagnosis hinges on separating *hypervisor* state from *guest*
health, and on getting the clocks and log windows right before drawing conclusions.

## `qm status: running` is not "guest healthy"

`qm status <id>` only tells you the hypervisor is scheduling the vCPU. A guest kernel can be
completely wedged and still read `running`. Guest-health probes are different tools:

| Probe | Command | A frozen guest shows |
|---|---|---|
| Network reachability | `ssh -v <host>` | hangs at `Connecting to ... port 22` (reachability class - **not** `Connection refused` = a bind/service fault, **not** `Permission denied` = auth) |
| Tailnet view | `tailscale status` | `offline, last seen ..., rx 0` (host sends, guest never replies) |
| Guest agent | WebUI reboot / `qm guest cmd` | `QEMU Guest Agent is not running - guest-ping got timeout` |
| ACPI | graceful shutdown | `powerdown failed - got timeout` |
| Last read path | `qm terminal <id>` (serial) | blank console, no login prompt, no echo on Enter |

If **guest-agent and ACPI both time out**, it is not "a service died" - the whole guest OS is
wedged. A dead `tailscaled` alone would still let the guest-agent answer.

## Recover only after graceful paths are exhausted

Graceful reboot (guest-agent, ACPI) already failed above, so the only lever left is a hard
power-cycle:

```
qm stop <id>     # QMP quit attempt, then the QEMU process is killed - the plug-pull equivalent
qm start <id>
```

A hard reset risks an unclean-shutdown journal replay; check the **host** disk layer is clean
first (below), which makes it low-risk. Do not reset before capturing whatever the serial
console shows - the reset erases it.

## Post-mortem: read the guest journal for the "last breath"

A hard freeze leaves a signature: the previous boot's journal **stops abruptly mid-operation**,
with **no shutdown sequence** (`Stopping...` / `Reached target Shutdown` are absent).

```
journalctl -b -1 -e                 # previous boot, jump to end - the last timestamp = time of freeze
journalctl -b -1 -k | grep -iE "oom|hung task|soft lockup|BUG:|call trace"
```

If the kernel grep is empty, it was a silent hard freeze with no logged cause - name that
honestly rather than inventing one. What you *can* still do is exclude classes (host disk, host
OOM, vfio/nvidia) from the **host** side.

## The two traps that misread the timeline

**1. Guest clock vs host clock.** A VM often runs `Etc/UTC` while the host runs local time
(e.g. CEST, +2h). Confirm with `timedatectl` on **both**. If you don't align the offset first,
the guest's "01:41" can look like it falls inside a window the host was powered off - which is
impossible, and the contradiction is the tell that the clocks differ. Align, *then* reason.

**2. Absence of data is not absence of a problem.** An empty host-journal window can mean "no
errors" **or** "the host wasn't logging then" (scheduled overnight shutdown, non-persistent
journal). Disambiguate before concluding:

```
uptime -p                    # was the host even up across the window?
journalctl --list-boots      # persistent? which boot covers the timestamp?
journalctl --since "<host-local time> ..." --until "..."   # query in HOST-clock terms, not guest
```

## Detection != response

Monitoring can be perfect and the outage still long. Here `NodeDown` + `ServiceDown` fired ~4 min
after the freeze and stayed firing for 8 h - the gap was that the alert reached a chat channel at
night and nobody acted, and nothing auto-recovered. For a hobby node the proportionate fix is a
**guest watchdog** (`i6300esb` QEMU device + `softdog`) that resets a wedged guest automatically,
not a 03:45 page. Note the in-guest **NMI watchdog is unreliable under KVM** (it needs hardware
PMU counters that are poorly virtualized), so don't count on it to catch a lockup.

## Related

- [LXC & VM Management](lxc-vm-management.md) - `pct`/`qm`, passthrough safety
- [Hard Shutdown Recovery](hard-shutdown-recovery.md) - LXC boot failures after a forced power-off
- [Time Synchronization](../linux/time-synchronization.md) - system clock vs RTC, why drift breaks alert math
- [systemd Basics](../linux/systemd-basics.md) - journalctl filtering, `--list-boots`
