# Tailscale Exit Nodes: the Stale Pin

Symptom: `tailscale up` kills internet access. LAN and Tailnet peers stay
reachable. Nothing in the local config was changed.

Root cause encountered: a Mullvad exit node pinned **by node ID** was
decommissioned upstream. Tailscale kept the dead reference, installed the
default route anyway, and reported no error.

---

## The failure class

A client preference references a server-side resource by opaque ID.
The resource is deleted upstream. The client never revalidates the reference
and never surfaces the dangling pointer - it just acts on it.

This is not Tailscale-specific. Same shape as a Terraform state entry pointing
at a destroyed cloud resource, a systemd unit referencing a removed device,
or a bookmarked DHCP reservation for a MAC that no longer exists. The rule:

> **A stored ID is a claim about the past. Only a live listing is evidence
> about the present.**

Corollary for debugging: never accept the config file as proof that the
referenced thing exists.

## Why it presents as "no internet" and not "VPN broken"

Tailscale does not route exit-node traffic through the main routing table.
It installs its own table and a policy rule that outranks the normal default
route:

```bash
ip rule show
```
```
5270:  from all lookup 52          # Tailscale's table - wins
32766: from all lookup main       # the real default route - never consulted
```
```bash
ip route show table 52            # exit-node default route lives here
```

With an exit node set, table 52 holds a default route via `tailscale0`.
Priority 5270 beats 32766, so every packet is handed to a peer that does not
exist. They are dropped silently.

`ExitNodeAllowLANAccess: true` keeps the local subnet reachable, which makes
the router, printer, and homelab all work. That masks the diagnosis - it feels
like a DNS or WAN problem rather than a routing problem.

## Diagnosis

Split routing from name resolution first:

```bash
ping -c2 -W2 1.1.1.1      # IP only  -> tests routing
ping -c2 -W2 google.com   # name     -> tests routing + DNS
```

Both failing while LAN works points at the default route, not at DNS.

Read the stored preferences:

```bash
tailscale debug prefs
```

Fields that matter:

| Field | Meaning |
|---|---|
| `ExitNodeID` | Pinned node, opaque ID. **The suspect.** |
| `AutoExitNode` | `"any"` when auto-selection is active (mutually exclusive with a pin) |
| `InternalExitNodePrior` | Previous exit node, kept so GUI toggles can restore it |
| `ExitNodeAllowLANAccess` | Why LAN still works while WAN is dead |
| `RouteAll` | `--accept-routes`; unrelated to this bug but the other common breaker |
| `WantRunning` | Whether the backend is up |

Then compare against reality:

```bash
tailscale exit-node list | grep -i "<ExitNodeID>" || echo "NOT FOUND - stale pin"
```

This is the decisive test. Absence is the finding.

### Journal evidence

```bash
journalctl -u tailscaled --since "-90d" | grep -E 'pm: using backend prefs'
```

Prints the full pref struct at every daemon start:

```
pm: using backend prefs for "profile-XXXX": Prefs{ra=false dns=true want=true
exit=nhFT86vct921CNTRL lan=true routes=[] ...}
```

Identical across every boot proves the config did not change - so the
environment did. Useful for answering "but I didn't touch anything".

**Trap:** `grep -c "<node-id>"` over the journal returns a high count and looks
like the node exists. Every hit is this same pref echo, not a resolved peer.
Counting occurrences answers the wrong question. Grep for the *resolved
hostname* instead, or trust `exit-node list`.

Node rotation is visible in the same log:

```bash
journalctl -u tailscaled --since "-90d" | grep -oE '[a-z]{2}-[a-z]{3}-wg-[0-9]+' | sort -u
```

Observed 20 distinct Mullvad hostnames over 90 days; the Frankfurt pool went
from `wg-101..104 / 202 / 301..303 / 401..403` down to `wg-101` alone.
Mullvad rebuilds WireGuard servers frequently. Pinning one is a time bomb.

## Fix

Stop pinning. Use auto-selection, which resolves a live node at every start:

```bash
tailscale set --exit-node=auto:any --exit-node-allow-lan-access=true
```

`auto:any` drives the same suggestion engine already visible in the log as
`netmap: suggested exit node: <hostname>`. It survives upstream rotation;
a hostname or ID does not.

Verify against the provider, not against local state:

```bash
curl -s --max-time 10 https://am.i.mullvad.net/connected
```
```
You are connected to Mullvad (server de-fra-wg-202). Your IP address is ...
```

Rescue command if a change kills connectivity - works offline, since the CLI
only talks to the local unix socket:

```bash
tailscale set --exit-node=
```

### Dead-man's switch for risky changes

When a change may sever the connection you are working over, arm a rollback
before making it:

```bash
setsid nohup bash -c \
  'for i in $(seq 90); do [ -f /tmp/ts.cancel ] && exit 0; sleep 1; done;
   /usr/bin/tailscale set --exit-node=' >/dev/null 2>&1 &
# ... make the change, verify ...
touch /tmp/ts.cancel    # disarm
```

`setsid` detaches from the terminal session, `nohup` blocks SIGHUP, `&`
backgrounds it - all three are needed so the watchdog outlives the shell.
A cancel *file* polled once per second beats `kill`, because the PID of a
`setsid` child is not reliably reachable from the caller.

## `tailscale up` flag-preservation trap

`tailscale up` resets every unmentioned flag to its factory default. If a
non-default pref exists it refuses and prints the full command:

```
Error: changing settings via 'tailscale up' requires mentioning all
non-default flags.
	tailscale up --exit-node-allow-lan-access
```

That suggestion can be self-contradictory: `--exit-node-allow-lan-access`
is rejected without `--exit-node`. So after clearing the exit node, `up`
demands a flag it will not accept.

Resolution: normalise the orphaned pref first, then start.

```bash
tailscale set --exit-node-allow-lan-access=false
tailscale up
```

**Do not use `tailscale up --reset` as the shortcut.** It also clears
`OperatorUser`, after which every `tailscale` command needs `sudo`.
`set` changes one field; `up` rewrites the whole pref set. Prefer `set`.

## Immutable-OS note (Bazzite / Fedora Silverblue)

`AutoUpdate.Apply: true` cannot work on an ostree system - `/usr` is read-only
and Tailscale ships in the image. The daemon retries hourly and fails:

```
offline auto-update: running "systemd-run --wait --pipe --collect /usr/bin/tailscale update --yes"
offline auto-update: update command failed: exit status 1
```

```bash
tailscale set --auto-update=false
```

Updates come via `rpm-ostree upgrade` with the rest of the image.

## Misleading correlation

The outage appeared to be Wi-Fi-specific. It is not: Tailscale prefs are
**per profile, not per interface** - there is no Wi-Fi/Ethernet distinction
in them. The real correlate was *changing networks* - three different subnets in one
evening, each triggering a reconnect that re-applied the dead pin.

Generalisation: "it only happens on X" is a hypothesis about a variable you
noticed, not about the variable that matters. Check whether the suspected
variable is even representable in the config before trusting it.

## Related

- [Tailscale](tailscale.md)
- [Tailscale Debugging](tailscale-debugging.md)
- [nftables alongside Tailscale](nftables-with-tailscale.md)
