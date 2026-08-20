# Glossary

The register of terms used in this homelab. It exists because an explanation built on an
unexplained word is not an explanation - it just moves the gap one layer down.

**How this file is used.** Before any explanation is written, every term and abbreviation in it is
checked against this register. A term that is not here gets a full explanation on the spot - what it
is, where it appears in this setup, and why it matters - and is then added here. A term that is here
may be used directly, with a link.

Entries answer three questions in order: **what it is**, **where it lives here**, and **why it
matters**. The third one is the reason the entry exists at all; a definition without consequences is
a dictionary, not a register.

---

## corosync

**What it is.** The cluster communication layer of Proxmox. It carries the heartbeat between nodes
and decides which of them are currently reachable. It is the component that makes several physical
machines behave as one cluster.

**Here.** Installed and `enabled`, but `inactive`, and there is no `/etc/pve/corosync.conf`. This
host is a standalone node - there is no cluster for corosync to talk to.

**Why it matters.** Several Proxmox features assume corosync is running and quorate. When a document
says "HA needs a quorate cluster", corosync is what provides the quorum. On a single node those
features are technically present and practically meaningless, which is a trap rather than a
convenience - see [HA](#ha-high-availability) and [quorum](#quorum).

## D-state (uninterruptible sleep)

**What it is.** A process state. A process in `D` is waiting for the kernel to finish something and
cannot be interrupted - not by `Ctrl+C`, not by `kill -9`. Signals are not delivered until the wait
ends. The classic cause is disk I/O; the other common one is a filesystem that has stopped
answering.

**Here.** During [KE-21](../homelab-server-architecture/docs/platform/known-errors.md#ke-21) roughly
twenty-two processes sat in this state, waiting on a dead [FUSE](#fuse) mount. The load average read
22 while the machine was otherwise idle.

**Why it matters.** Two consequences that surprise people:

- **Load average counts D-state.** A load of 22 does not mean the machine is busy; it means
  twenty-two tasks are runnable *or* blocked. Load 22 with no CPU and no disk activity is the
  signature of a lock, and it is a diagnosis rather than a symptom.
- **You cannot kill your way out.** The usual reflex - find the process, `kill -9` it - does nothing
  here. Recovery means fixing what it waits on, or rebooting.

## ECC (Error-Correcting Code memory)

**What it is.** Memory that stores extra check bits, so the memory controller can detect and repair
single-bit errors and at least detect larger ones. Non-ECC memory has no such check: a flipped bit
is silently handed to the software as if it were the value that was written.

**Here.** `Error Correction Type: None`. The RAM has no error correction.

**Why it matters.** It changes what the absence of an error message proves. On an ECC machine, "no
[MCE](#mce-machine-check-exception) was logged" is real evidence that memory was not at fault. Here
it proves nothing at all, because a corrupted bit produces no report by design. That is why
[KE-21](../homelab-server-architecture/docs/platform/known-errors.md#ke-21) can name a probable
software cause but cannot exclude hardware.

## EDAC (Error Detection And Correction)

**What it is.** The Linux subsystem that reports memory and cache errors from the hardware, and the
interface through which ECC events would surface.

**Here.** Initialised at boot (`EDAC MC: Ver: 3.0.0`), and reporting nothing - which follows from the
memory having no [ECC](#ecc-error-correcting-code-memory) to report on.

## fencing

**What it is.** Forcibly cutting a node off - usually by resetting it - so that a cluster can safely
start its workloads elsewhere. The purpose is not to repair the node but to *guarantee* it is no
longer writing to shared storage. A node that is merely unreachable might still be running.

**Here.** Not in use, and deliberately so. It becomes relevant only if [HA](#ha-high-availability)
is enabled.

**Why it matters.** Fencing is the reason a watchdog under HA is dangerous on a single node. The
logic is "if I lose contact with the cluster, I must reset myself" - correct in a cluster, where
another node takes over. On a standalone machine there is nothing to take over, so a transient
software hiccup would produce a hard reset of every running guest and gain nothing.

## FUSE (Filesystem in Userspace)

**What it is.** A kernel interface that lets an ordinary program provide a filesystem. The kernel
forwards each read or write to that program and waits for its answer. `sshfs`, `mergerfs`, and
Proxmox's own `/etc/pve` all work this way.

**Here.** Three of them: [pmxcfs](#pmxcfs) on `/etc/pve`, `mergerfs` on the storage VM's archive
pool, and [lxcfs](#lxcfs) on `/var/lib/lxcfs`.

**Why it matters.** A FUSE filesystem is only as available as the process behind it. If that process
dies, the mountpoint does not report an error - it simply stops answering, and every reader waits.
Two properties follow that both showed up in
[KE-21](../homelab-server-architecture/docs/platform/known-errors.md#ke-21):

- FUSE waits are *killable* uninterruptible sleep, which means the kernel's hung-task detector
  ignores them. A wedged FUSE mount raises the load average for hours without ever producing the
  `blocked for more than 120 seconds` warning you would expect.
- `node_exporter` is the one collector with a mount timeout, so it survives a wedged mount and
  reports `device_error="mountpoint timeout"`. That label is the fastest way to identify this class.

## HA (High Availability)

**What it is.** In Proxmox, a subsystem that restarts guests on another node when the node running
them fails. It needs a cluster, a quorum, and a way to guarantee the failed node is really down -
which is [fencing](#fencing).

**Here.** The services (`pve-ha-lrm`, `pve-ha-crm`) are running and enabled, but there is no cluster,
so they have nothing to manage. This is the default Proxmox state, not something that was configured.

**Why it matters.** "High availability" sounds like a general improvement, so it invites being
switched on. On a single node it cannot deliver its purpose - there is no second machine to move
guests to - while it does bring its full set of consequences, above all self-fencing. The platform
here is deliberately recovery-oriented rather than highly available: the design accepts downtime and
invests in being able to come back.

## idempotency

**What it is.** The property of an operation that leaves the same end state however often it runs.
Once or five times, the machine looks identical afterwards. It is not the same as "harmless to
repeat": a script that appends a line on every run does no damage, but it is not idempotent, because
the fifth run leaves five lines.

**Here.** It is the design principle behind every Ansible module this repository uses -
`ansible.builtin.user`, `copy` and `authorized_key` all read the current state before writing - and
it is what makes `--check --diff` meaningful at all. Hand-written scripts on this fleet are held to
the same bar: the lxc250 bootstrap script appends the SSH key only when `grep -qxF` does not already
find it, and writes the sudoers file only when it differs.

**Why it matters.** The whole verification habit rests on it. "Run it again and see whether anything
changes" is only a test when unchanged input means unchanged output; a `changed=0` from a re-run is
then evidence that the live state matches the declared one. Where idempotency breaks, repetition
accumulates silently - two identical `authorized_keys` lines, two cron entries, two exporter units.
This platform has already paid for that once, with the second hand-written `tailscaled` unit on
lxc220 that started a duplicate daemon at every boot.

## kernel oops

**What it is.** A kernel-detected fault - it dereferenced a bad pointer, or hit an inconsistent
internal structure. The kernel kills the offending task, prints a diagnostic with a call trace, and
keeps running. It is the kernel equivalent of a crash that was survived rather than a clean error.

**Here.** Seven of them on 2026-08-20, starting at 12:38:25. See
[KE-21](../homelab-server-architecture/docs/platform/known-errors.md#ke-21).

**Why it matters.** "Keeps running" is doing a lot of work in that sentence. The killed task may have
held locks or left a shared structure half-modified, so the system afterwards is *undefined* rather
than *degraded*. That is precisely what happened here: the first oops corrupted a
[slab](#slab-allocator) freelist, and every later allocation from that cache faulted in turn. The
sysctl `kernel.panic_on_oops` decides whether the machine keeps limping or stops immediately - see
[sysctl](#sysctl).

## kex (SSH key exchange)

**What it is.** The first phase of every SSH connection, before authentication. Both sides send a
version identification string, agree on algorithms, and derive a shared session key. Only once that
succeeds does anything else travel the wire - user names, keys, and the command itself. OpenSSH names
its functions after it, which is why client errors from this phase read
`kex_exchange_identification`.

**Here.** It is the phase a failed connection to the hypervisor died in on 2026-08-20, and the reason
that failure left no trace on the host: `sshd` had not yet forked the per-connection `sshd-session`
process that writes the `Accepted publickey` line. The client-side message was the only evidence.

**Why it matters.** It tells you how far a failed SSH attempt got, which is usually the whole
question. An error naming kex means no authentication was attempted and no remote command ran - so
whatever the command would have done, it did not do. A failure after kex is the opposite case and
deserves the opposite assumption. Distinguishing the two is the difference between "nothing happened"
and "something half happened".

## LRM and CRM (Local / Cluster Resource Manager)

**What they are.** The two halves of Proxmox [HA](#ha-high-availability). The **LRM** runs on every
node and starts, stops and monitors the HA-managed guests on that node. The **CRM** is the
cluster-wide decision maker - one node holds this role - and decides where a guest should run.

**Here.** `pve-ha-lrm` and `pve-ha-crm` are both active, with no cluster and no HA-managed guests, so
neither does anything.

**Why it matters.** The LRM is the component that would connect to
[watchdog-mux](#watchdog-mux) and thereby arm the watchdog. That connection is the entire mechanism
behind "arming softdog", and it is also the path that brings [fencing](#fencing) along with it.

## lxcfs

**What it is.** A [FUSE](#fuse) filesystem that gives each container its own view of
`/proc/meminfo`, `/proc/cpuinfo`, `/proc/stat` and `/proc/uptime`. Without it, `free` inside a
container reports the whole host's memory, and `top` reports the host's CPUs.

**Here.** `/var/lib/lxcfs`, served by the `lxcfs` service on the Proxmox host, used by all eight
containers.

**Why it matters.** It is a single point of failure that does not look like one. Nothing depends on
lxcfs for *storage*, so it reads as cosmetic - but every login reads `/proc/meminfo` through PAM,
and `pvestatd` reads container statistics through it. When its worker thread died, container logins,
guest status reporting, systemd and therefore every new SSH session blocked. The failure surfaced as
"the whole hypervisor is unreachable".

## MCE (Machine Check Exception)

**What it is.** A hardware-raised error report from the CPU - uncorrectable memory errors, cache
errors, bus faults. The kernel decodes and logs them.

**Here.** In-kernel decoding is enabled; none has been logged.

**Why it matters.** Only as strong as the hardware underneath. Without [ECC](#ecc-error-correcting-code-memory)
memory, a memory fault produces no MCE, so silence is not evidence of health. This is the same shape
as `smartctl -H PASSED` on a disk with 7680 unreadable sectors: a check that cannot fail is not a
check.

## pct (Proxmox Container Toolkit)

**What it is.** The Proxmox command-line tool for LXC containers, addressed by numeric ID:
`pct start 250`, `pct exec 250 -- <command>`, `pct push`, `pct reboot`, `pct fstrim`. It runs on the
hypervisor, not inside the guest.

**Here.** It is the break-glass route into every container. `pct exec 250 -- bash` is the documented
fallback during the 30-60 s window after boot in which lxc250's sshd has no Tailscale address to bind
to; `pct fstrim` is what reclaims thin-pool blocks that a container cannot reclaim itself;
`pct reboot 210` was what repaired Nextcloud's bind mount after the share appeared underneath it.

**Why it matters.** It reaches the guest through the host kernel's namespaces, bypassing the guest's
network, its sshd and its hardening entirely. That is precisely why it is the recovery path when
hardening has locked the door - and why it leaves no trace in the container's own audit trail. One
caution from [KE-21](../homelab-server-architecture/docs/platform/known-errors.md#ke-21): a series of
deeply nested `pct exec` one-liners immediately preceded the kernel oops. Causation was never
established and the memory in this machine has no [ECC](#ecc-error-correcting-code-memory), so the
correlation is all there is. It is still the reason live fleet commands are now copied up as script
files instead of being nested four levels deep in quotes.

## PerSourcePenalties (OpenSSH)

**What it is.** A rate-limiting mechanism in `sshd`, on by default since OpenSSH 9.8. It records
source addresses whose connections end badly - authentication failure, a crash, exceeding the login
grace time, disconnecting without authenticating - and refuses further connections from that address
for a growing period. The defaults on this platform read
`crash:90 authfail:5 noauth:1 grace-exceeded:10 max:600 min:15`, in seconds of penalty per event.

**Here.** The Proxmox host runs OpenSSH 10.0p2 with the stock settings, so this is active without
anyone having configured it. It is one of two candidate explanations for a connection that was reset
during [kex](#kex-ssh-key-exchange) on 2026-08-20 while connections a minute earlier and a minute
later succeeded.

**Why it matters.** A penalised connection is refused before `sshd` forks the process that does the
logging, so at the default `LogLevel INFO` the rejection appears nowhere in the journal. A gap in the
log is therefore not evidence that nothing was attempted, and troubleshooting an intermittent SSH
failure by reading the server's log alone can point at exactly the wrong layer. Raising `LogLevel` to
`VERBOSE` is what makes the mechanism visible.

## pmxcfs (Proxmox Cluster File System)

**What it is.** The [FUSE](#fuse) filesystem mounted at `/etc/pve`. It is not an ordinary directory:
it is a database that presents itself as files, and in a cluster it replicates them to every node.
Guest configurations, storage definitions and user accounts all live in it.

**Here.** Healthy throughout the 2026-08-20 incident - which was worth measuring, because it was the
first suspect and would have explained the same symptoms.

**Why it matters.** Two practical consequences. Configuration management must never write into
`/etc/pve` with ordinary file tasks; use `pct`, `qm` and `pvesh`, which go through the proper
interface. And when the Proxmox interface misbehaves, pmxcfs is worth checking early - but check it,
do not assume it, since a plausible suspect and a guilty one are different things.

## PSI (Pressure Stall Information)

**What it is.** A kernel interface that reports how much time tasks spent *waiting* for CPU, memory
or I/O, rather than how much resource was used. Exported by `node_exporter` as
`node_pressure_*_seconds_total`.

**Here.** During the incident, I/O stall ran at about 1 % and CPU pressure at 0.2 % while the load
average read 22.

**Why it matters.** It separates "busy" from "blocked", which the load average cannot. High load with
near-zero pressure means the tasks are not waiting for a resource at all - they are waiting on a
lock. That single comparison ruled out both a disk problem and a runaway process in one step, and it
is the most useful diagnostic pair on this platform: **load says how many are waiting, pressure says
what they are waiting for.**

## quorum

**What it is.** The rule a cluster uses to decide whether it is allowed to act: a majority of nodes
must be reachable. Its purpose is to prevent a split-brain, where two halves of a partitioned
cluster each believe they are in charge and both write to shared storage.

**Here.** Not applicable - a single node is trivially its own majority.

**Why it matters.** Because the *logic* is still present even where the situation is not. Under
[HA](#ha-high-availability), a node that believes it has lost quorum self-fences. On a single node
there is no genuine loss of quorum to detect, only false positives - which is the core argument for
leaving HA switched off here.

## slab allocator

**What it is.** The kernel's allocator for its own small, frequently reused objects. It keeps
per-type caches, each holding a *freelist*: a linked list of free slots, where each free slot stores
the pointer to the next one.

**Here.** The cascade in [KE-21](../homelab-server-architecture/docs/platform/known-errors.md#ke-21)
ran through it - six consecutive faults in `kmem_cache_alloc_noprof`.

**Why it matters.** It explains why one fault became a system-wide failure. Because the freelist
lives *inside* the free memory it tracks, corrupting one slot poisons the chain. Every later
allocation from that cache follows the bad pointer and faults - so unrelated processes die one after
another with an identical error. Seeing the same faulting address repeat across different programs
is the signature: one corruption event, re-read many times, not many separate faults.

## softdog

**What it is.** A software watchdog: a kernel timer that resets the machine if nothing writes to
`/dev/watchdog` within its timeout. "Software" means the timer lives in the kernel, as opposed to a
hardware watchdog implemented in the chipset.

**Here.** Loaded and providing `/dev/watchdog`, held open by [watchdog-mux](#watchdog-mux), and not
armed. The chipset's hardware watchdog module (`sp5100_tco`) exists but is not loaded.

**Why it matters.** A watchdog answers a different question from
[`panic_on_oops`](#sysctl): not "did the kernel fault" but "has anything been alive recently".
Its limit is worth knowing - softdog is a kernel timer, so a completely locked-up kernel takes the
watchdog down with it. Only a hardware watchdog survives that case, which is the argument for
preferring `sp5100_tco` if it works on this board.

## sudoers.d and NOPASSWD

**What it is.** `/etc/sudoers.d/` is a drop-in directory that `sudo` reads in addition to
`/etc/sudoers`; each file holds a fragment of policy, so a package or a role can add its own rule
without editing a shared file. The `NOPASSWD:` tag on a rule means the listed commands run without
sudo asking for the invoking user's password.

**Here.** `/etc/sudoers.d/ansible` on every managed node, containing one line -
`ansible ALL=(ALL) NOPASSWD: ALL` - written by `bootstrap-ansible-user.yml` with mode `0440` and
checked by `visudo -csf` before it is put in place. lxc250 is the node that has been missing it.

**Why it matters.** It is what makes `become: true` work unattended: a password prompt in a
non-interactive SSH session does not fail, it hangs. The cost is stated plainly - whoever holds the
Ansible private key holds unprompted root on every node in the inventory, which is why that key
living unbackuped on a single container is its own open item. The two guards around the file are not
decoration: mode `0440` keeps it unwritable, and the syntax check matters because a malformed file in
this directory makes `sudo` refuse to run at all, on a node where root SSH is already disabled.

## sysctl

**What it is.** The interface for kernel tunables at runtime - `sysctl kernel.panic_on_oops` reads
one, `sysctl -w` sets one for this boot, and a file in `/etc/sysctl.d/` makes it survive a reboot.

**Here.** All crash-related tunables are at their defaults: `kernel.panic = 0`,
`kernel.panic_on_oops = 0`, `kernel.hardlockup_panic = 0`, `kernel.softlockup_panic = 0`.

**Why it matters.** The two that decide how a crash ends:

- **`kernel.panic_on_oops`** - `0` means the kernel survives an [oops](#kernel-oops) and keeps going
  in an undefined state; `1` means it stops immediately.
- **`kernel.panic`** - how many seconds to wait after a panic before rebooting. `0` means halt
  forever.

Together they turn "the machine is alive and unreachable" into "the machine rebooted". On a host with
no out-of-band console, that trade is almost always worth taking.

## taint flags

**What they are.** A set of markers the kernel carries once something has happened that makes its
state less trustworthy. They appear in every oops report: `P` for a proprietary module, `O` for an
out-of-tree module, `D` for "this kernel has already oopsed".

**Here.** `P O` from the ZFS modules, plus `D` from the first oops onwards.

**Why it matters.** It is the cheapest way to order a series of crashes. The first report on
2026-08-20 read `P O` with no `D`, every later one carried `D` - which is what identifies the first
as the cause and the rest as consequences. Without that flag the seven reports would just be seven
crashes.

## watchdog-mux

**What it is.** The Proxmox service that owns `/dev/watchdog`. It is a multiplexer: exactly one
process may hold a watchdog device, so this one holds it and lets several Proxmox services register
with it over a socket.

**Here.** Running, holding `/dev/watchdog`, with no clients connected.

**Why it matters.** It only arms the watchdog once a client registers, and the client would be the
[LRM](#lrm-and-crm-local--cluster-resource-manager). So the watchdog is present but inert, and the
only Proxmox-native way to activate it drags in [HA](#ha-high-availability) and
[fencing](#fencing). It also explains why systemd's own watchdog cannot simply be switched on: the
device is taken, so systemd needs either a second device or watchdog-mux out of the way.
