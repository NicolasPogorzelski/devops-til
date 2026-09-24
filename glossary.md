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

## 3-2-1 rule (and 3-2-1-1-0)

**What it is.** Three copies of the data, on two kinds of media, one of them off site. The extended
form adds two digits: 3-2-1-1-0, where the extra 1 is a copy that is immutable or physically
disconnected, and the 0 is the number of errors in the last restore test.

**Here.** The first three digits are satisfied. The fourth is what the
[off-site decision](../homelab-server-architecture/docs/decisions/offsite-backup-target.md) is about. The zero is already
practised: the PostgreSQL restore test runs monthly into a throwaway cluster, and the guest backup
was restored by hand on 2026-08-21.

**Why it matters.** Each digit answers a different threat. Three copies covers accidental deletion,
two media covers a media defect, one off site covers site loss, the extra 1 covers ransomware and a
stolen credential, and the 0 covers the question that decides the day - whether it restores.

## air gap

**What it is.** Keeping a copy off any network path that could reach it, usually by physically
disconnecting the medium.

**Here.** The disk at a family member's home, recorded in
[data classification](../homelab-server-architecture/docs/platform/data-classification.md), is a real air gap: off site,
disconnected, and of unknown age between visits.

**Why it matters.** Nothing on a network can reach it, which is the strongest guarantee available.
The weakness is that a person has to perform it, and this one is refreshed only when its owner
visits the household that holds it. An air gap with no cadence has an unknown age between refreshes,
so it works as a last resort and not as a planned control. That gap is most of the argument for
paying for an off-site target that can be scheduled.

## Alertmanager

**What it is.** The component that turns a firing Prometheus rule into a notification. Prometheus
decides only *that* an alert fires; it has no idea where to send it. Alertmanager receives firing
alerts, groups, deduplicates and silences them, and hands them to a receiver.

**Here.** A container on lxc200 alongside Prometheus, Grafana, node_exporter and the
[blackbox exporter](#blackbox-exporter). Its route has one receiver, `discord`, with
`send_resolved: true`, so the recovery arrives in the same channel as the alert.

**Why it matters.** It is the second half of every alert path and it fails independently of the
first. A rule reaching `firing` in Prometheus proves the detection worked; it does not prove anybody
was told. When asking "why did nothing warn me", check both halves separately -
`ALERTS{alertstate="firing"}` in Prometheus, and the receiver in Alertmanager.

## ansible_managed

**What it is.** A string Ansible offers inside templates, meant for a header line such as
`# {{ ansible_managed }}` that tells a reader the file is generated and hand edits will be lost.
It is defined while the `template` module renders a file and nowhere else.

**Here.** `journal_remote` used it inside `ansible.builtin.copy: content:`, where it is undefined,
so the play failed with `'ansible_managed' is undefined` - measured 2026-09-24 in the drift sweep's
`journal-central` run. The two `.j2` templates in the same roles use it correctly.

**Why it matters.** The failure is not a check-mode artefact: the real apply fails the same way. A
header that works in one module and breaks in the one beside it is easy to copy across without
noticing, and only a run shows it.

## append-only (backup target)

**What it is.** A mode in which a storage endpoint accepts new data and refuses deletion and
overwriting. `rest-server`, the restic REST backend, implements it with `--append-only`: the
credential can create snapshots and read them, and every delete is rejected at the server.

**Here.** The property the off-site backup target was chosen for
([decision](../homelab-server-architecture/docs/decisions/offsite-backup-target.md)). It is why
`restic forget` and `restic prune` fail from the homelab by design and retention runs on the server
under a different account.

**Why it matters.** Backups usually fail as a credential problem rather than a media problem: any
account that can write them can normally delete them, and ransomware and a mistaken script both use
that. Append-only breaks the symmetry. It is weaker than object storage's Object Lock, which the
provider enforces and nobody can override, because whoever holds root on the server can still
remove files - the residual risk is stated rather than designed away.

## AppImage

**What it is.** A single executable file carrying an application and its libraries, which mounts
itself at run time instead of being installed. Nothing lands in the package manager's database.

**Here.** How Collabora Online runs on lxc210: the `richdocumentscode` Nextcloud app extracts an
AppImage into `/tmp` and starts `coolwsd` from it as `www-data`. That is why the node has no
`coolwsd` package and no `coolwsd` unit while a process listens on port 9983.

**Why it matters.** It sits outside every mechanism this platform uses to know what it runs.
`dpkg -l` does not list it, `systemctl` does not manage it, no Ansible role can own it without
owning the app that ships it, and its files live in `/tmp` on the container's root disk. A component
that arrives this way skips the new-service checklist without anybody deciding to skip it.

## blackbox exporter

**What it is.** A Prometheus exporter that probes a target from outside instead of reading metrics
from inside it. Prometheus scrapes the exporter and passes the target URL as a parameter; the
exporter performs the HTTP request (or TCP connect, or ICMP ping) and answers with `probe_success`
1 or 0.

**Here.** A container on lxc200. It probes Jellyfin and Audiobookshelf on vm100 by port, and the
`tailscale serve` services by MagicDNS name. The `ServiceDown` rule (`probe_success == 0`,
`for: 3m`) is built on it.

**Why it matters.** It is the only layer that sees a *service* being down while its node is
perfectly healthy - the gap KE-8 named. node_exporter runs on the node and reports the node; if a
container there never starts, every node metric stays green. The probe sits outside the failure,
which is precisely what lets it observe one.

## capabilities and CAP_DAC_OVERRIDE

**What it is.** Linux splits root's historical powers into around forty capabilities, so a process
can hold one without holding all. `CAP_DAC_OVERRIDE` is the one that skips file permission checks.

**Here.** Inside LXC220, root could not read `/opt/calibreweb`
([KE-22](../homelab-server-architecture/docs/platform/known-errors.md#ke-22)). Capabilities are scoped to the user namespace
that holds them, so container root has `CAP_DAC_OVERRIDE` over owners the
[UID map](#user-namespace-and-uid-mapping) covers and none over owners it does not.

**Why it matters.** "root can do anything" stopped being true when user namespaces arrived, and
habits older than that still assume it. When a privileged process in a container gets `EACCES`,
check whether the file's owner exists inside the namespace before looking at mode bits.

## CDI (Container Device Interface)

**What it is.** A specification for handing hardware to a container declaratively. A vendor writes a
spec file - YAML listing device nodes, libraries and mounts under a name such as
`nvidia.com/gpu=all` - and the container runtime reads it and applies it. It replaces the older
approach of running a vendor program during container startup.

**Here.** vm100 uses it for the GPU. `nvidia-ctk cdi generate`, run from
`nvidia-cdi-refresh.service`, writes `/var/run/cdi/nvidia.yaml`; dockerd resolves the Jellyfin
container's device request `nvidia.com/gpu=all` against it.

**Why it matters.** The spec file lives on [tmpfs](#tmpfs), so it is gone after every boot, and
`nvidia-cdi-refresh.service` carries `After=multi-user.target`, which places it after
`docker.service` rather than before. So at every boot dockerd finds no spec, logs
`unresolvable CDI devices nvidia.com/gpu=all`, and falls back to the legacy
[OCI hook](#oci-hook-prestart-hook). The declarative path is configured and never used at boot; the
fragile path is the one that runs.

## CodeQL

**What it is.** GitHub's code-scanning engine. It builds a queryable database from source and runs
queries against it to find security defects. The `github/codeql-action` repository ships it as a
set of Actions, one of which - `upload-sarif` - does something unrelated to scanning: it publishes
a [SARIF](#sarif-static-analysis-results-interchange-format) file to a repository's Security tab.

**Here.** CodeQL analysis does not run. Only `github/codeql-action/upload-sarif` is used, in
`.github/workflows/image-scan.yml`, to publish Trivy's findings. The repository holds
documentation, YAML and shell, none of which CodeQL supports well enough to be worth the minutes.

**Why it matters.** The name in the workflow reads as if code scanning were happening, and it is
not. `upload-sarif` is the generic publishing endpoint that happens to live in the CodeQL
repository, which is also why Dependabot's weekly pull requests carry `codeql-action` in the title
for a repository that runs no CodeQL. Read the sub-path, not the repository name.

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

## CTID (container ID)

**What it is.** The numeric identifier Proxmox gives every guest. Containers and virtual machines
share one number space, so a CTID is unique across the whole host and never reused while the guest
exists. Every `pct` command addresses a container by it, and `qm` addresses a VM the same way.
Proxmox stores the configuration under that number: `/etc/pve/lxc/<ctid>.conf` for a container,
`/etc/pve/qemu-server/<vmid>.conf` for a VM.

**Here.** The numbers carry meaning by convention rather than by rule - 200 monitoring, 210
Nextcloud, 240 Vaultwarden, 250 the control node, 260 PostgreSQL, and 100/102 for the two VMs. The
node documents and the Ansible inventory use the same names (`lxc240`, `vm102`), so a CTID is
usually readable as a node name and back.

**Why it matters.** Anything that runs on the hypervisor addresses guests by CTID and knows nothing
about the Ansible inventory: `vzdump`, `pct fstrim`, `pct exec`. That is why the guest backup keeps
working for a node that has been removed from the inventory, and equally why a hardcoded list of
CTIDs in a script drifts out of step with `pct list` without anything noticing. Never identify a
guest by its position in a list; identify it by CTID.

## CVE (Common Vulnerabilities and Exposures)

**What it is.** A globally unique identifier for one publicly disclosed vulnerability, in the form
`CVE-2026-12345`. It names the flaw; it does not say whether a given system is exploitable through
it. Severity is expressed separately, usually as a CVSS score bucketed into LOW / MEDIUM / HIGH /
CRITICAL.

**Here.** `image-scan.yml` runs [Trivy](#trivy) over the images the repository pins and counts
findings by severity with `jq`, selecting `.Severity == "CRITICAL"` and `"HIGH"` from the JSON
output. The same scan is written again as SARIF and published to the Security tab, one category
per image. Measured 2026-08-17 and still true: no stack on the fleet runs a pinned image, so the
scan describes files in a repository rather than processes on a node.

**Why it matters.** The count was the useful measure while the
[KE-13](../homelab-server-architecture/docs/platform/known-errors.md#ke-13) hold forbade pulling
new layers onto a failing disk: it answers "how badly is the running thing exposed" without
proposing a change that was not allowed. That hold was lifted on 2026-09-05, which turns the
number from a status report into a work queue - 139 fixable critical and 2162 high at the last
count. Note what a count does not establish: a CRITICAL in a package the service never calls is
not an incident, and triage still has to happen by hand.

## CVSS (Common Vulnerability Scoring System)

**What it is.** The severity a [CVE](#cve-common-vulnerabilities-and-exposures) identifier does not
carry. A number from 0.0 to 10.0, computed from a vector of properties - whether the flaw is
reachable over a network or only locally, whether it needs credentials, whether it needs a user to
act, and what it costs in confidentiality, integrity and availability. The number is bucketed:
0.1-3.9 LOW, 4.0-6.9 MEDIUM, 7.0-8.9 HIGH, 9.0-10.0 CRITICAL.

**Here.** Those buckets are what `image-scan.yml` counts. Every "139 critical, 2162 high" in this
platform's documents is a tally of CVSS buckets reported by [Trivy](#trivy), not a judgement about
this fleet.

**Why it matters.** The score published with an advisory is the Base score, and it describes the
flaw in isolation: it knows nothing about a platform with no public ingress, where every service
sits behind a Tailscale ACL. A CRITICAL in a container reachable from two tagged devices scores
exactly what the same CRITICAL scores on an exposed port. The standard has metric groups for
that - Temporal and Environmental - and almost nobody fills them in, so the bucket says how much
work a finding might be and nothing about how exposed this platform is to it.

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

## Dependabot

**What it is.** A GitHub service that watches a repository's declared dependencies and opens pull
requests when newer versions appear. It does two separate jobs. *Version updates* are configured in
`.github/dependabot.yml` and fire whenever something newer exists. *Security updates* are a
repository setting rather than a file, and fire only when a published advisory affects a version
actually in use.

**Here.** Version updates cover GitHub Actions only, weekly on Friday, at most five open pull
requests, with `commit-message.prefix: ci` and `include: scope` so the generated subject satisfies
`scripts/commit-msg-lint.sh`. The Docker images under `docker/` are deliberately excluded: they are
pinned on purpose and `docker-compose-update` is under a standing hold until the aux-disk is
replaced, so a stream of proposals that must not be applied would be noise. Advisory-driven
security updates stay on.

**Why it matters.** Actions here are pinned to commit SHAs rather than tags, and a SHA never
updates itself. The pin buys immutability and pays for it in permanent staleness; Dependabot is the
counter-movement, with a human in between. Without it the workflows would sit on whatever was
current the day they were written. The Friday schedule matches the weekly fleet audit, so the
review lands in a slot that already exists instead of arriving as an interrupt.

## Depends and Recommends (Debian packages)

**What it is.** Two strengths of package relationship. `Depends` is mandatory: the package cannot
be installed without it, and apt pulls it in. `Recommends` is installed by default too, but can be
refused with `--no-install-recommends` (or `install_recommends: false` in Ansible's apt module)
without breaking anything.

**Here.** On Debian 12, `prometheus-node-exporter-collectors` lists `prometheus-node-exporter` - a
complete second exporter daemon - under `Depends`. Installing the collectors for `apt_metrics` on
lxc260 therefore installed and started it; on the Trixie hypervisor the dependency is gone. Read
it with `apt-cache show <package> | grep -E '^(Depends|Recommends)'`.

**Why it matters.** A `Depends` cannot be switched off with a flag, only neutralised after the
fact - here by masking the unit before the install. Assuming a helper package is inert is how
lxc260 ended up with two exporters fighting over one port.

## DevOps

**What it is.** A way of working in which the people who build a system also run it, rather than
handing it over a boundary to a separate operations team. It shows up as three habits rather than
as a job title: infrastructure described in version-controlled files instead of assembled by hand,
delivery automated so a change reaches the running system the same way every time, and that system
measured so its state is a reading rather than an opinion.

**Here.** The homelab repository is the artefact. Every guest-side change is an Ansible role, every
scheduled job a systemd timer, and each node reports through `node_exporter` into Prometheus. The
counter-example is the shape this platform keeps finding: a hand-written unit in
`/etc/systemd/system` that no role owns, which works perfectly until the node is rebuilt and then
does not exist. The host `node_exporter` and the LVM thin-pool collectors were both in that state
for months.

**Why it matters.** It decides whether a fault can be reproduced. A configuration that lives only
on the machine has no history, so "it used to work" cannot be checked against anything, and the
person diagnosing it is reading the current state and guessing at the previous one. The same
property is what makes [idempotency](#idempotency) worth having at all.

## DevSecOps

**What it is.** [DevOps](#devops) with the security review moved into the pipeline instead of
appended to the end of it. The novelty is not the checks, it is when they run. A finding at the
moment code is written costs a rewrite of that code; the same finding at release costs the release;
the same finding after publication cannot be undone at all.

**Here.** `validate-repo.sh` runs as a pre-commit hook and again in CI, `ansible-lint` on every
push, [CodeQL](#codeql) and Trivy on a schedule, [Dependabot](#dependabot) weekly. The
sanitization checks are the clearest case of the timing argument: the homelab repository is public,
so an address that reaches a commit is public the moment it is pushed, and no review afterwards
takes it back.

**Why it matters.** The failure this discipline exists to prevent is a control that is asserted
rather than measured. `security-controls.md` carries a status column for exactly that reason, and
it has been wrong: A.8.5 read *Enforced* for weeks while two nodes still accepted passwords. A
false assurance suppresses discovery more effectively than a stated gap does, because nobody looks
at a row that already says yes.

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

## ExecStartPre

**What it is.** A systemd service directive naming a command to run before the unit's own
`ExecStart`. It runs to completion first, and a non-zero exit aborts the start: the unit goes to
`failed` and `ExecStart` never runs. Several may be listed and they run in order.

**Here.** The readiness half of every boot gate on this fleet. `wait-for-tailscale-ip.sh` polls
until the Tailscale address is actually assigned to an interface, and only then does the gated
unit start - `pveproxy` on the hypervisor, `node_exporter` on nine guests, PostgreSQL on lxc260,
sshd on lxc250.

**Why it matters.** It is the difference between ordering and readiness, which is the
[KE-18](../homelab-server-architecture/docs/platform/known-errors.md#ke-18) class. `After=` only
promises that systemd started the other unit, and a daemon counts as started while it is still
negotiating; `ExecStartPre` lets a unit wait for a condition rather than for a neighbour. The
trap is the other half of the sentence: because a failing `ExecStartPre` blocks the start
entirely, a gate script must be fail-open - `wait-for-tailscale-ip.sh` logs a warning and exits 0
on timeout, so a gated unit starts late rather than not at all. That property is what makes it
safe to put in front of sshd.

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

## file descriptor

**What it is.** A small integer a process uses to refer to something the kernel opened for it - a
file, a pipe, a network socket. The number is meaningful only inside that process. Descriptors
survive `fork()`, so a child inherits its parent's open files, and they survive `execve()` unless
marked close-on-exec, which is how a program can be replaced while keeping its connections.

**Here.** It is the mechanism behind [socket activation](#socket-activation): systemd opens the
listening socket for port 22 itself and passes the descriptor to `ssh.service`, so `ss -lntp` shows
both `systemd` and `sshd` as owners of the same socket. It is also why a restarted daemon under
socket activation loses no connections - the descriptor stays open in systemd while the service is
away.

**Why it matters.** Inheriting a socket and binding one look identical from outside and are not the
same act. The whole of [KE-24](../homelab-server-architecture/docs/platform/known-errors.md#ke-24)
is a daemon that should have reused an inherited descriptor and tried to bind instead.

## frontmatter

**What it is.** A metadata block at the very top of a text file, fenced above and below by a line
of three hyphens and written in YAML. Tools read it; readers skip it. Static site generators use it
for titles and dates, and it is the usual way to attach machine-readable fields to a document
without inventing a second file.

**Here.** Not used in either repository - every markdown file starts with its `#` heading. It
appears in the assistant's memory files outside both repos, which carry `name`, `description` and a
`type`. The confusion worth naming is the `---` that opens every Ansible YAML file: that is the
YAML document-start marker, a single line with nothing above it and no closing counterpart, and it
means "a document begins here", not "metadata follows".

**Why it matters.** Two constructs that look identical do different jobs, and only one of them has
a closing delimiter. Deleting the `---` from a playbook because it "looked like empty frontmatter"
is a plausible edit that `ansible-lint` will then object to.

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

## getent

**What it is.** A small command that asks glibc's own name-service switch a question and prints the
answer - `getent hosts <name>`, `getent passwd <user>`, `getent group <group>`. The point is which
code path it uses: it resolves exactly the way an ordinary program does, through `/etc/nsswitch.conf`
and whatever sources that file lists, rather than talking to a name server directly.

**Here.** It is the verification step of the `nsswitch` role. After the role rewrites the `hosts:`
line on lxc250, it calls `getent ahostsv4` against the node's own MagicDNS name and fails the run if
the lookup does not answer.

**Why it matters.** `dig` and `nslookup` query a resolver of their own choosing and bypass the
switch entirely, so both answered correctly on lxc250 the whole time MagicDNS was broken for every
other program on the node. A tool that proves the resolver works proves nothing about whether
anything can reach it. `getent` is the one that asks the question the applications ask.

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

## hook output fields (Claude Code)

**What it is.** A Claude Code hook speaks through JSON on stdout. Three fields carry
different meanings: `additionalContext` is text added to the model's context, which on
`Stop` means "keep going" rather than "remind"; `systemMessage` is a banner shown to the
user and leaves the model alone; `permissionDecision` (`allow`, `deny`, `ask`) is the
verdict of a `PreToolUse` hook on one tool call. A hook that exceeds its `timeout` does not
block - the call proceeds.

**Here.** `hooks-reference.json` in the homelab repository, `~/.claude/settings.json` and
`.claude/settings.local.json` on both workstations; the pre-commit guard answers with
`permissionDecision: deny`, the devops-til reminder with `systemMessage`.

**Why it matters.** The wrong field is not an error, it is a different behaviour: the
reminder written as `additionalContext` re-invoked the model on every turn end (measured
2026-09-17), and a guard timeout is the width of a bypass, not a safety margin.

## hrtimer interrupt warning

**What it is.** The kernel message `hrtimer: interrupt took N ns`. A high-resolution timer interrupt
should finish in microseconds. When one takes milliseconds the kernel prints this once and widens
its own tolerance. It is not a fault in the timer - it is evidence that the CPU was not available
when the interrupt was due.

**Here.** vm100 logged `interrupt took 11834745 ns` (11.8 ms) at 20:55:02 on 2026-08-24, at the end
of a 33-second stall in which the Jellyfin GPU hook timed out.

**Why it matters.** Inside a virtual machine this usually means the *host* did not schedule the
guest's vCPU, not that the guest was busy. It is one of the few signals a guest gets for host-side
contention, which is otherwise invisible from within. Read it as a timestamped marker of "this VM
was starved here" and line it up against whatever timed out.

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

## KillMode

**What it is.** A systemd service directive deciding who receives the signal when a unit is
stopped. The default, `control-group`, signals every process in the unit's cgroup, including
anything it forked. `process` signals only the main process and leaves the children running.
`mixed` sends SIGTERM to the main process and SIGKILL to the rest.

**Here.** Debian's `ssh.service` carries `KillMode=process`, which is why an open SSH session
survives `systemctl restart ssh`: the listening daemon is replaced while the per-session child
that carries your shell is left alone.

**Why it matters.** It is the reason a configuration change to sshd can be applied over sshd at
all. Under the default, restarting the service from a play that arrived through it would take
down the connection mid-change - and on a node with no out-of-band console that is the end of the
session. It also sets the shape of the precaution around such a change: the risk is never the
existing session, it is whether a *new* one can still be established afterwards, which is why the
old one stays open until a fresh one is proven.

## logical vs physical path (symlinks)

**What it is.** A symlink makes one path name stand for another. The *logical* path is
the name you used, symlinks intact; the *physical* path is what remains after every
symlink is resolved. `pwd` and `$PWD` give the logical form, `pwd -P`, `readlink -f`
and `git rev-parse --show-toplevel` give the physical one.

**Here.** On the rpm-ostree workstations `/home` is a symlink to `/var/home`, so
`$HOME=/home/admin` and `/var/home/admin` name the same directory. On every node
`/var/run` is a symlink to `/run`.

**Why it matters.** Two tools looking at the same directory can return different strings,
and a string comparison between them is false. The homelab's commit guard compared a
`pwd`-derived root with a `rev-parse`-derived one and silently stepped aside on the
gaming PC - see [Claude Code Hooks](operations/claude-code-hooks.md). Any config that
stores an absolute path should store the physical one.

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

## memtest86+

**What it is.** A memory tester that boots instead of the operating system and writes and reads
patterns across every address the firmware reports. It has to run outside a running system, because
memory in use cannot be tested.

**Here.** One of the four remediation steps [KE-21](../homelab-server-architecture/docs/platform/known-errors.md#ke-21)
left open: the oops cascade that wedged the hypervisor has no confirmed cause, and bad memory is
one of the few candidates that can be ruled in or out rather than argued about.

**Why it matters.** It is the step that has not happened, and the reason is instructive. It needs
physical presence and a boot that does not reach Proxmox, so it cannot be scheduled the way the
other three can. A verification that requires a person in the room stays open longer than one that
requires a command, which is why it is written into a runbook rather than a list of intentions.

## netconsole (and netpoll)

**What it is.** A kernel module that sends the kernel log as UDP datagrams to another machine.
It writes them through `netpoll`, a path inside the kernel that drives the network card directly
without the normal networking stack or any userspace process.

**Here.** vm100 streams its kernel log to the Proxmox host, where a `socat` unit writes it into the
persistent journal. Deployed by the `netconsole` role on the sending side and, since 2026-09-11, by
`proxmox_host_units` on the receiving side.

**Why it matters.** It is the only channel that still works while a guest is freezing. That is also
why the receiver binds the LAN address rather than the Tailscale one, a documented exception to this
platform's binding rule: a Tailscale address lives on a TUN device served by a userspace daemon,
and that daemon is frozen along with everything else during exactly the failure being captured.

## nftables

**What it is.** The Linux kernel's packet filter, and the successor to iptables. Rules live in named
tables attached to hooks in the network path; `nft -f <file>` loads a file, and a table can be
replaced or deleted on its own without touching the others.

**Here.** Two filters, both enforcing a boundary a service cannot enforce itself: `smb_guard` on
vm102, because Samba cannot bind an IPv4 address on `tailscale0`, and `local_guard` on lxc210 via
the `nft_guard` role, because Collabora offers no listen-address setting at all.

**Why it matters.** A kernel filter is evaluated before the daemon accepts the connection, unlike
an application's own allow-list, which runs after the TCP accept. The trap on this platform is the
loading mechanism rather than the rules: the stock `nftables.service` begins with `flush ruleset`
and flushes everything on stop, either of which would delete the chains Tailscale maintains. Both
filters therefore carry their own unit and never a `flush ruleset`.

## nmi_watchdog

**What it is.** A kernel mechanism that uses a performance counter to raise a non-maskable interrupt
periodically, detecting a CPU stuck in the kernel with interrupts disabled - a hard lockup, which no
ordinary timer can observe because the timer never fires.

**Here.** Considered and set aside in the
[hypervisor panic decision](../homelab-server-architecture/docs/decisions/hypervisor-panic-and-watchdog.md).

**Why it matters.** It looks like the middle option between doing nothing and enabling the HA stack
for `softdog`, and it is not one on its own: its default action is to log, which on a host nobody
can reach produces another record of a machine nobody can reach. It becomes useful combined with
`panic_on_oops`, where a hard-lockup panic inherits the reboot - a combination worth measuring on
the hardware rather than assuming from a manual page.

## nowayout

**What it is.** A module parameter carried by most Linux watchdog drivers. It decides what happens
when the process holding `/dev/watchdog` closes it. At `nowayout=0` the kernel stops the timer on
close; at `nowayout=1` it keeps counting and the machine resets whatever the userspace process
does. Closing "properly" means writing the magic character `V` first, and the distinction only
matters at `nowayout=0`.

**Here.** The hypervisor loads [softdog](#softdog) at `nowayout=0` - read from the kernel's own
line at load, `softdog: initialized. soft_noboot=0 soft_margin=60 sec soft_panic=0 (nowayout=0)`,
with `CONFIG_WATCHDOG_NOWAYOUT` unset in the running kernel. The parameter is not exposed under
`/sys/module/softdog/parameters`, so the journal is where it is read.

**Why it matters.** It answers whether a crashed watchdog daemon takes the host with it. A process
that dies has its descriptors closed by the kernel, so at `nowayout=0` the timer stops and the
machine keeps running: losing the daemon costs the watchdog. At `nowayout=1` the same crash is a
reset in one timeout period, which is the point on a machine that must fence itself, and a trap on
one that must not.

## nsswitch.conf

**What it is.** The file that tells glibc which sources to consult for names, and in which order:
`hosts: files resolve [!UNAVAIL=return] dns` means try `/etc/hosts`, then `systemd-resolved`, and
consult DNS only if resolved was unavailable. The bracketed action is the part that catches people -
it ends the lookup on the named condition instead of falling through.

**Here.** Why MagicDNS does not resolve on lxc250. `resolved` is available and simply does not know
the tailnet's names, so it answers NXDOMAIN, `[!UNAVAIL=return]` ends the search, and the correct
`/etc/resolv.conf` that `tailscaled` wrote is never read.

**Why it matters.** Nothing was misconfigured in any sense a person would grep for. Two resolvers
were present, one of them knew the answer, and the ordering meant the lookup never reached it. The
fix chosen was to remove `resolve` from the line rather than to teach `resolved` the tailnet, on the
grounds that the smallest honest change is to stop short-circuiting a lookup that already works.

## nvcgo

**What it is.** The cgroup component of the NVIDIA container toolkit. `nvidia-container-cli` does
not manipulate cgroups in its own process; it calls a helper over an RPC - a remote procedure call,
meaning the caller invokes a function that runs in a different process and waits for the reply.
`nvcgo` is that helper, and the call has a timeout.

**Here.** It appears on vm100 only in failure messages:
`nvidia-container-cli: initialization error: nvcgo rpc error: timed out`, emitted by the legacy
[OCI hook](#oci-hook-prestart-hook) while starting the Jellyfin container.

**Why it matters.** Being a timeout, it fails on a *slow* machine rather than a broken one - so it
is a boot-window failure by nature, striking exactly when the system is most loaded and least
watched. Six occurrences in vm100's journal since January, every one during startup.

## Object Lock (WORM)

**What it is.** A property of an object in S3-compatible storage that forbids deleting or
overwriting it until a retention date passes. WORM is the older name: write once, read many.
Enforcement sits on the storage side, so it binds the account owner too.

**Here.** Considered and not chosen for the off-site backup target
([decision](../homelab-server-architecture/docs/decisions/offsite-backup-target.md)), which went to an append-only
`rest-server` on a VPS instead. The entry is kept because it names what that choice gave up.

**Why it matters.** Distance answers fire. It does not answer a stolen credential, and on this
platform the control node already holds hypervisor root, so an account that can reach everything
exists. Object Lock is the one option where the guarantee does not depend on the operator
configuring it correctly, because the storage service refuses the deletion. Everything else,
append-only servers included, is that property rebuilt by hand and therefore capable of being
misconfigured or switched off.

## OCI hook (prestart hook)

**What it is.** OCI, the Open Container Initiative, standardises the on-disk container format and
the runtime that starts it. Its runtime specification lets a container config declare *hooks*:
external programs the runtime executes at defined points. A `prestart` hook runs after the
container's namespaces exist but before its main process starts - the moment at which devices can
be injected from outside.

**Here.** `/usr/bin/nvidia-container-runtime-hook`, injected by dockerd as a prestart hook for the
Jellyfin container whenever the [CDI](#cdi-container-device-interface) path is unavailable. It calls
`nvidia-container-cli`, which sets up the GPU device nodes and driver libraries inside the container.

**Why it matters.** A failing prestart hook is fatal to `runc create`, so the container never
reaches the running state at all. That distinction is what lets the failure survive a
[restart policy](#restart-policy-docker): a policy reacts to a container that ran and exited, and a
hook failure means it never ran.

## onboot

**What it is.** A per-guest Proxmox setting deciding whether the host starts that guest
automatically when it boots. `onboot: 1` starts it, `onboot: 0` leaves it stopped. It lives in the
guest's config file and is read during host startup. A related key, `startup`, orders the guests
that do start and can hold a delay.

**Here.** The host powers down every night and wakes on an RTC alarm, so `onboot` is what actually
brings the platform back - a guest with `onboot: 0` stays down until somebody starts it by hand.
Clearing it was step one of withdrawing lxc240 from service: stopping a guest without clearing
`onboot` means the next wake undoes the shutdown silently.

**Why it matters.** "Stopped" and "will stay stopped" are two different states, and `pct status`
only reports the first. On a host that reboots on a schedule, the second is the one that decides
what is running tomorrow.

## OT (Operational Technology)

**What it is.** The hardware and software that controls and measures physical processes - sensors,
actuators, programmable logic controllers, and the control systems of factories, substations and
water works. The contrast is with IT, which processes data. The difference inverts the priorities:
IT ranks confidentiality, integrity and availability in that order, while OT puts availability and
physical safety first, because a patch that stops a turbine for ten minutes can cost more than the
vulnerability it closes. Lifetimes differ by an order of magnitude too - a controller installed in
2004 is ordinary, and it cannot be patched into something modern.

**Here.** There is none. Nothing in this homelab controls a physical process, and no entry in it
should suggest otherwise.

**Why it matters.** It is carried as a review perspective rather than as a system to defend. The OT
seat asks what the maintenance window is, which changes cannot be reversed while the thing is
running, and which machines are not simply restarted. Those questions have concrete answers here:
vm100 cannot be snapshotted, so every change to it is one-way; the hypervisor's physical recovery
path is unavailable while the GPU is passed through, so a bad sshd reload there has no second
route in; and [KE-13](../homelab-server-architecture/docs/platform/known-errors.md#ke-13) is a
failing disk kept in service under a standing hold rather than replaced on discovery. Read from an
IT seat those are inconveniences. Read from an OT seat they are the constraints that decide what
may be attempted at all, which is why the platform has no [HA](#ha-high-availability) and is
designed for recovery instead.

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

## Persistent=true (systemd timers)

**What it is.** A timer option: if the machine was off when an `OnCalendar=` time passed, the job
runs as soon as the timer is next started - normally at boot - instead of waiting for the next
scheduled time. systemd records the last run under `/var/lib/systemd/timers/`.

**Here.** Every daily job on the fleet carries it, because the host powers down overnight and a
plain calendar time at night would simply never fire. The catch-up runs a few minutes into uptime:
on 2026-09-24 the MariaDB dump finished about three minutes after boot, which is why the backup
staleness rules carry `for: 15m`.

**Why it matters.** It is why the backups exist at all on a machine that sleeps, and also why an
alert evaluated in the first minutes after boot can see yesterday's timestamp. Cron has no
equivalent, which is what silently lost the PostgreSQL backups in June and July.

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

## pipx

**What it is.** Installs a Python command-line tool into its own virtual environment and
puts only the executable on `PATH`, so tools with conflicting dependencies coexist and
none of them touches the system Python.

**Here.** `ansible` and `ansible-lint` on lxc250 (`dotfiles/bootstrap.sh`), and the
`pipx install 'ansible-lint==26.6.0'` line the homelab `CLAUDE.md` prescribes for a
workstation.

**Why it matters.** The version pin is the point: `validate-repo.sh` Check 16 gates
commits against whatever `ansible-lint` is on `PATH`, and a version other than CI's
gates against a different rule set. On the rpm-ostree workstations there is no `pipx`;
[`uv`](#uv-and-uv-tool) fills the same role.

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

## privilege separation (OpenSSH)

**What it is.** OpenSSH splits the handling of a connection in two. A small privileged process does
only what needs root - reading the host key, opening the session - and everything that touches data
from the network runs in an unprivileged child, `chroot`ed into an empty directory owned by root.
A flaw in the parsing code then reaches a process with no privileges and no filesystem.

**Here.** That directory is `/run/sshd`, and `ssh.service` declares `RuntimeDirectory=sshd`, so
systemd creates it at start and removes it at stop. sshd refuses to run without it:
`Missing privilege separation directory: /run/sshd`.

**Why it matters.** It turns a stopped unit into a second, unrelated failure. When ssh.service died
during [KE-24](../homelab-server-architecture/docs/platform/known-errors.md#ke-24) the directory
went with it, and every later `sshd -t` failed on the missing directory rather than on the original
cause - a diagnosis one layer away from the fault, produced by the cleanup rather than the defect.

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

## repeat_interval (Alertmanager)

**What it is.** How long Alertmanager waits before sending a notification again for an alert group
that is still firing and has not changed. Distinct from `group_wait` (delay before the first
notification of a new group) and `group_interval` (delay before notifying about a change within a
group).

**Here.** `4h` on the `discord` route on lxc200. An alert that stays red therefore reappears in the
Discord channel every four hours with no new information, and the permanently firing Watchdog does
so too while its own route is not live.

**Why it matters.** Repetition is how a channel teaches its reader to stop reading. When the same
message arrives six times, check whether anything changed between them before treating each one as
news - on 2026-09-22/24, two notifications out of roughly twenty carried information.

## restic

**What it is.** A backup program that encrypts and deduplicates on the client before transmitting,
storing the result as content-addressed blobs in a repository - a local directory, an SSH target, or
an S3-compatible bucket. Unchanged data is not stored twice.

**Here.** The client for both the interim and the durable off-site copy
([decision](../homelab-server-architecture/docs/decisions/offsite-backup-target.md)).

**Why it matters.** Client-side encryption makes the operator of the target largely irrelevant,
which matters because the data includes identity documents. It also adds a failure mode: the
repository password cannot be recovered, so it has to live in the credential escrow rather than on
the machine being backed up.

## rpcbind (and nfs-common)

**What it is.** `rpcbind` is the port mapper for Sun RPC services: a client asks it which port a
program number listens on, which is how NFS clients and servers find each other. It is pulled in by
`nfs-common`, the Debian package carrying the NFS client tools.

**Here.** Installed on lxc210 and on the Proxmox host, neither of which has an NFS mount. On lxc210
it listened on `0.0.0.0:111` and `[::]:111` while the package's `run-rpc_pipefs.mount` failed at
every boot - the fault recorded as
[KE-3](../homelab-server-architecture/docs/platform/known-errors.md#ke-3) and masked rather than
fixed until 2026-09-11.

**Why it matters.** Two audit findings eight months apart turned out to be one package. The failed
mount was treated as a cosmetic nuisance and masked; the open port was recorded separately as a
binding-rule violation; nobody connected them. Removing the package closed both and retired the
mask, which is the general shape worth carrying: a mask is a statement that something cannot
succeed, and the next question is always why it is installed.

## rpm-ostree

**What it is.** The package layer of image-based Fedora variants (Silverblue, Bazzite).
The OS is an immutable image; `rpm-ostree install` layers a package on top and takes
effect at the next boot, `flatpak` is for applications, and `dnf` is not used for the
system.

**Here.** Both admin machines - Bazzite on the gaming PC, Fedora on the notebook - are
the operator side of every playbook and PR.

**Why it matters.** "Install a linter" is a reboot, so per-user tooling (`uv`, `brew`,
`flatpak`) is the normal route. And `/home` is a symlink to `/var/home` on these
systems, which is a path-comparison trap in its own right - see
[logical vs physical path](#logical-vs-physical-path-symlinks).

## RPO and RTO

**What they are.** Recovery Point Objective is how much data may be lost, expressed as time: an RPO
of 24 hours accepts a day's work as the worst case. Recovery Time Objective is how long recovery may
take.

**Here.** Stated per dataset in [data classification](../homelab-server-architecture/docs/platform/data-classification.md).
Several rows read "undefined" until 2026-09-01, which was the finding - an undefined RPO is unknown,
not zero.

**Why it matters.** They pick the mechanism. A 24-hour RPO permits a nightly dump; a one-hour RPO
does not, and no amount of care about the nightly dump closes that gap. Writing them down first
keeps a backup design from being chosen out of habit.

## restart policy (Docker)

**What it is.** A per-container setting telling the Docker daemon what to do when the container's
main process exits: `no`, `on-failure`, `always` or `unless-stopped`. `unless-stopped` means
"restart it, and start it again when the daemon starts, unless a human explicitly stopped it".

**Here.** Every compose stack in this homelab uses `restart: unless-stopped`.

**Why it matters.** The name invites a wrong reading. It is a policy about *exits*, not a supervisor
that keeps a container up. When dockerd cannot even create the container - a failing
[OCI hook](#oci-hook-prestart-hook), a missing bind mount, a device that is not ready - the
container never enters the running state, nothing ever exits, and the policy never applies. The
start is attempted once at daemon start and then dropped: `RestartCount` stays 0 and `FinishedAt`
still points at the previous clean shutdown, so `docker ps -a` prints `Exited (0)` and looks exactly
like a container somebody stopped on purpose. This is what kept Jellyfin down on vm100 on
2026-08-24 until it was started by hand.

## SARIF (Static Analysis Results Interchange Format)

**What it is.** A JSON schema for the output of static analysis tools - findings, locations,
severities, rule identifiers. It exists so that a platform can display results from a tool it knows
nothing about, and so that results from different tools can sit side by side.

**Here.** Trivy runs twice in `image-scan.yml` over the same images: once with JSON output, which
`jq` reduces to CRITICAL and HIGH counts, and once with `format: sarif` into `trivy.sarif`, which
`github/codeql-action/upload-sarif` publishes. Each image gets its own `category`, without which
every upload would overwrite the previous one.

**Why it matters.** It is the reason GitHub's Security tab can show container findings at all. The
`category` argument is the part that is easy to leave out and silently wrong: with one category for
several images, the tab shows the last upload and reports the earlier findings as fixed.

## scrub (SnapRAID)

**What it is.** Re-reading data already in the array and checking it against the parity, to find
bit rot that no read has touched. Distinct from `sync`, which computes parity for data that
changed. `snapraid scrub` with no arguments verifies about 8 % of the array per run, choosing
blocks older than ten days.

**Here.** Runs monthly on vm102. Measured 2026-08-17, the oldest block had gone 123 days unverified
and 74 % of the array had never been scrubbed, while `SnapRAIDScrubStale` read green.

**Why it matters.** It is the clearest case on this platform of a guard measuring that a job ran
rather than that it achieved something - the same shape as `smart_health_passed` reporting PASSED
for a disk with 7680 unreadable sectors. The arithmetic is the point: 8 % a month is roughly a year
for a full pass, so the coverage was not a fault but the schedule working as configured, and
nothing was reading the number that would have said so.

## seccomp

**What it is.** A Linux kernel facility that restricts which system calls a process may make. A
seccomp profile is the list; a call outside it is refused or kills the process.

**Here.** Switched off in the Collabora process on lxc210, together with capability-based jailing
(`--o:security.seccomp=false`, `--o:security.capabilities=false`). The AppImage sets both because
that jailing does not work inside an unprivileged LXC.

**Why it matters.** It is the layer that confines a program while it parses untrusted input, and a
document is untrusted input - Paperless feeds this instance from a consumption directory. Without
it, a malicious file that reaches a parser bug is confined by the container boundary and by nothing
inside it. See [capabilities and CAP_DAC_OVERRIDE](#capabilities-and-cap_dac_override).

## SIGHUP (and what sshd does with it)

**What it is.** A signal, historically "the terminal hung up", adopted by convention as "re-read
your configuration". The convention is not a rule, and each daemon decides what it means.

**Here.** `systemctl reload ssh` runs two commands from the unit: `/usr/sbin/sshd -t`, which parses
the configuration and aborts the reload if it is invalid, then `/bin/kill -HUP $MAINPID`. sshd does
not re-read anything on that signal. It calls `execve()` on itself and starts over with the same
PID, which is how a package upgrade takes effect without systemd losing track of the process.

**Why it matters.** Re-exec means the new process rebuilds everything the old one had, including
its listening socket. Under [socket activation](#socket-activation) that socket belongs to systemd,
the bind fails with `EADDRINUSE`, and the daemon exits - which is
[KE-24](../homelab-server-architecture/docs/platform/known-errors.md#ke-24). The general form: a
reload is not always a re-read, and the difference only shows where the process has state it cannot
recreate on its own.

## Setext heading (Markdown)

**What it is.** Markdown's older of two heading syntaxes. ATX headings lead with hashes
(`## Title`); a Setext heading instead *underlines* the text - `===` beneath a paragraph makes it
an H1, `---` makes it an H2. The rule fires whenever a non-blank paragraph is followed immediately
by such a line, which is exactly one blank line away from the same characters meaning a horizontal
rule.

**Here.** Every heading in both repositories is ATX, so a Setext heading is always an accident.
One happened on 2026-09-15: an explanatory paragraph placed directly above a `---` section divider
rendered on GitHub as a three-line H2. Nothing caught it, because every heading check in
`validate-repo.sh` reads a leading hash. Check 42 now scans for the pattern, skipping list items,
table rows, fenced code and YAML frontmatter, where those characters mean something else.

**Why it matters.** It is a silent formatting fault: the source looks right, the renderer disagrees,
and no linter in a documentation repository need notice. A blank line is the whole fix.

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

## smartmon.sh and prometheus-node-exporter-collectors

**What it is.** A Debian package of textfile-collector scripts for node_exporter. `smartmon.sh` is
the one that reads every SMART attribute of every disk with `smartctl` and prints it as Prometheus
metrics - `smartmon_<attribute>_value`, `_worst`, `_threshold` and `_raw_value`, plus a
`smartmon_device_info` line carrying model and serial.

**Here.** Deployed on the Proxmox host by the `smart_metrics` role since 2026-09-09, replacing a
hand-written collector that exported two metrics.

**Why it matters.** The metric the hand-written collector exported, `smart_health_passed`, read
PASSED for a disk with 7680 unreadable sectors, because the drive's own self-assessment normalises
that attribute against a threshold it can never cross. The per-attribute export is what makes the
question answerable at all: not whether a disk calls itself healthy, but whether its error counters
moved since yesterday.

## socat

**What it is.** A relay between two byte streams of almost any kind - sockets, files, pipes,
devices. `socat -u UDP4-RECV:6666,bind=<addr>,reuseaddr -` reads datagrams from one address and
writes them to standard output; `-u` makes it unidirectional, so it never writes back.

**Here.** The whole implementation of the netconsole receiver on the Proxmox host. systemd captures
its standard output into the journal under a fixed identifier.

**Why it matters.** A one-line `ExecStart` with no code to maintain, which is the right amount of
machinery for a log relay. The failure mode it introduces is worth naming: if the binary is missing
the unit dies with 203/EXEC at every boot, which is how `fleet-snapshot.service` failed on its first
start, so the role installs the package rather than assuming it.

## socket activation

**What it is.** systemd opens a listening socket itself and starts the service only when a
connection arrives, passing the open [file descriptor](#file-descriptor) to it. With `Accept=no`
one service instance receives the listening socket and handles every connection; with `Accept=yes`
systemd forks an instance per connection. The socket keeps listening while the service is stopped,
crashed or restarting, so connections in that window are queued in the backlog rather than refused.

**Here.** The Proxmox Debian 12 container template enables `ssh.socket` - `Accept=no`,
`ListenStream=22` - so lxc200, lxc210, lxc211, lxc220, lxc230 and lxc260 run sshd this way. vm100,
vm102, lxc250 and the Proxmox host have it disabled and run the daemon on its own. Both units
active is the correct steady state on the six, not a collision.

**Why it matters.** Two consequences pull in opposite directions. A restart under socket activation
is gentler than elsewhere, because nothing is refused while the service is away. But `ListenAddress`
in `sshd_config` has no effect - the socket unit decides what is listened on - so the platform
binding rule would have to be written as `ListenStream=<tailscale-ip>:22`, an address that does not
exist yet at boot, which is
[KE-18](../homelab-server-architecture/docs/platform/known-errors.md#ke-18) one layer down. And a reload becomes unsafe, for the reason in
[SIGHUP](#sighup-and-what-sshd-does-with-it).

## softdog

**What it is.** A software watchdog: a kernel timer that resets the machine if nothing writes to
`/dev/watchdog` within its timeout. "Software" means the timer lives in the kernel, as opposed to a
hardware watchdog implemented in the chipset.

**Here.** Loaded and providing `/dev/watchdog`, held open by [watchdog-mux](#watchdog-mux). Read
2026-09-16, the device is `active` at a ten-second timeout, not idle - what is missing is a client
that could stop the petting, since no HA resource is configured. It is loaded at
[`nowayout=0`](#nowayout). The chipset's hardware watchdog module (`sp5100_tco`) exists but is not
loaded.

**Why it matters.** A watchdog answers a different question from
[`panic_on_oops`](#sysctl): not "did the kernel fault" but "has anything been alive recently".
Its limit is worth knowing - softdog is a kernel timer, so a completely locked-up kernel takes the
watchdog down with it. Only a hardware watchdog survives that case, which is the argument for
preferring `sp5100_tco` if it works on this board.

## sponge (moreutils)

**What it is.** A small utility that reads all of its input before it writes any output. `cmd |
sponge file` is the safe form of `cmd > file`, which truncates the file before the command has
produced anything.

**Here.** In the `ExecStart` of the packaged smartmon collector unit, writing `smartmon.prom`.

**Why it matters.** A textfile collector is read by node_exporter on its own schedule, so a plain
redirect exposes a window in which the file is empty or half written and the metrics simply vanish
for a scrape. Absent is not zero: a rule written as `> 0` reads an absent metric as silence rather
than as a fault.

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

## supply chain attack

**What it is.** An attack that reaches a target through something the target depends on, rather
than through the target itself - a compromised library, base image, package repository or CI
action. The defender's own code can be flawless and still execute the attacker's.

**Here.** A GitHub Actions workflow runs third-party code on a machine that has the repository
checked out and can hold write access to it, which makes an Action the shortest path in. Every
Action in `.github/workflows/` is therefore pinned to a commit SHA with the version in a trailing
comment: `actions/checkout@3d3c42e5... # v7.0.1`. A tag such as `v7` is mutable and the publisher
can move it; a SHA cannot be moved. Container images are pinned the same way one level down, by
version tag, and `apache/tika` by `@sha256:` digest, which is the stronger form.

**Why it matters.** It is why [Dependabot](#dependabot) is needed rather than optional: the SHA pin
closes the hijack path and freezes the code at the same time, and something has to unfreeze it
deliberately. The remaining manual step is checking that a proposed SHA really belongs to the tag
named in the comment - `gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq '.object.sha'` - which
is the one thing the bot cannot vouch for on its own behalf.

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

## tentative (systemd device unit state)

**What it is.** The sub-state of a systemd `.device` unit that systemd knows about - from a mount
table entry or a unit referring to it - but that udev has not tagged with `systemd`. The unit sits
in `activating (tentative)` and never becomes active.

**Here.** `dev-fuse.device` on the Proxmox host, measured 2026-09-09: `activating/tentative`, empty
`ActiveEnterTimestamp`, while `/dev/fuse` is open by lxcfs and pmxcfs and works.

**Why it matters.** It looks exactly like a hung unit and is not one, which cost the
`SystemdUnitStuckActivating` rule a false positive on the day after it was written - one that would
have returned after every boot. See [udev](#udev).

## thin pool (LVM)

**What it is.** An LVM volume that hands out space on demand rather than at creation. Volumes carved
from it may promise more in total than the pool holds, and blocks are allocated when they are first
written.

**Here.** `pve/data` on the Proxmox host, holding every VM and LXC root disk.

**Why it matters.** Two properties bite. A pool that fills stops every guest on it at once, and it
is a block-layer object with no filesystem, so `node_filesystem_*` cannot see it - which is why it
went from 86 % to 93 % in thirteen days in 2026 with no rule able to notice, and why it now has its
own textfile collector. And freeing a file inside a guest does not return blocks to the pool: the
guest has to discard them, and a container cannot `fstrim` itself.

## tmpfs

**What it is.** A filesystem held in memory. It looks like an ordinary directory tree, is read and
written like one, and is empty again after a reboot. Linux mounts several by default, `/run` among
them.

**Here.** `/run` on every node, and through the `/var/run` -> `/run` symlink also `/var/run/cdi`,
the directory holding vm100's generated [CDI](#cdi-container-device-interface) spec.

**Why it matters.** A file on tmpfs is not state, it is a cache with no owner. Anything depending on
it acquires an implicit ordering requirement against whatever regenerates it, and that requirement
is invisible in the consuming config - nothing in `docker.service` mentions `/var/run/cdi`. Same
shape as [KE-18](../homelab-server-architecture/docs/platform/known-errors.md#ke-18): a resource
that exists in steady state and does not exist yet at boot.

## Trivy

**What it is.** A vulnerability scanner for container images and filesystems. It unpacks an image
layer by layer, extracts the installed packages - the `dpkg` status database on a Debian base,
plus language manifests such as `package-lock.json` or `requirements.txt` - and matches every
version against vulnerability databases. Each finding names a [CVE](#cve-common-vulnerabilities-and-exposures),
the package, the installed version and the version that fixes it. "Fixable" means that last field
is filled in.

**Here.** `image-scan.yml` runs it weekly, twice over the same images: once as JSON, which `jq`
reduces to [CVSS](#cvss-common-vulnerability-scoring-system) bucket counts, and once as
[SARIF](#sarif-static-analysis-results-interchange-format) for the Security tab.

**Why it matters.** The repository pins exact version tags and the fleet runs `:latest` and
`:main`, measured 2026-08-17, so the weekly result describes an image nobody has started. The workflow's own comment claims the compose files "cannot drift
from reality", which is the assumption that measurement contradicted. Until the pinned files are
deployed, read every count as a lower bound on something adjacent.

## udev

**What it is.** The Linux device manager. It handles kernel events about devices appearing and
disappearing, creates the nodes under `/dev`, and applies rules that set permissions, symlinks and
tags.

**Here.** The reason `/dev/fuse` on the hypervisor has no `systemd` tag, which is what keeps its
device unit tentative.

**Why it matters.** Tags are how udev tells systemd which devices are worth having units for. A
device without one still works perfectly; only systemd's view of it stays incomplete. Reading the
unit state instead of the device is how that turns into a false alarm.

## ugrep (in the Claude Code tool shell)

**What it is.** A grep implementation with its own regex engine, bundled into the Claude
Code binary. Inside the tool shell `grep` is a shell function that redirects to it
(`type -a grep` shows the function); the function is not exported, so scripts and hooks
started from that shell still run the system GNU grep.

**Here.** Bazzite gaming PC, Claude Code 2.1.274, `/usr/bin/grep` is GNU grep 3.12
underneath.

**Why it matters.** A pattern tested with bare `grep` in the tool shell can behave
differently from the same pattern in a hook or in `validate-repo.sh`. The push-refusal
regex looked correct under ugrep and did not match a plain `git push` under GNU grep.
Test hook and script patterns with `/usr/bin/grep` or `command grep`.

## uv (and `uv tool`)

**What it is.** A Python package and project manager. `uv tool install <pkg>` is the
`pipx` shape - isolated environment under `~/.local/share/uv/tools/`, shim in
`~/.local/bin/` - and `uvx` runs a tool once without installing it.

**Here.** `ansible-lint==26.6.0` on the gaming PC, installed 2026-09-17 with
`uv tool install` because the immutable OS has no `pipx`.

**Why it matters.** The repository's check asks only whether the pinned `ansible-lint`
is on `PATH`; how it got there is a workstation detail. `uv` is that detail on the
rpm-ostree machines, `pipx` on the Debian control node - same guarantee, different
installer.

## user namespace and UID mapping

**What it is.** A namespace that translates user and group IDs between the inside and the outside of
a container. Proxmox unprivileged containers use `u 0 100000 65536`: container UID 0 is host 100000,
container 1000 is host 101000, for 65536 IDs. The permitted ranges come from `/etc/subuid` and
`/etc/subgid`. When a file's host owner falls outside the map the kernel cannot translate it and
reports `/proc/sys/kernel/overflowuid` instead, conventionally 65534 or `nobody`.

**Here.** Every LXC on this platform is unprivileged. It is why storage mounted into LXC220 needs
`chown 100000:100000`, and why a directory owned by host UID 1000 was unreadable inside the
container that held it ([KE-22](../homelab-server-architecture/docs/platform/known-errors.md#ke-22)).

**Why it matters.** A container escape lands on an unprivileged host account instead of root, which
is most of the security argument for unprivileged containers. The cost is that ownership means two
different things depending which side you ask from, and `nobody` in a container listing is often the
kernel declining to answer rather than a real owner. See also
[capabilities](#capabilities-and-cap_dac_override).

## vzdump

**What it is.** Proxmox's backup tool for VMs and containers. `--mode snapshot` archives a
storage-level snapshot so the guest keeps running; `stop` and `suspend` are the consistent but
disruptive alternatives. Unprivileged containers are archived through
`lxc-usernsexec -m u:0:100000:65536`, inside the guest's
[UID map](#user-namespace-and-uid-mapping), so the archive records container-relative ownership.

**Here.** The weekly guest backup
([runbook](../homelab-server-architecture/runbooks/platform/guest-backup-restore.md)), covering nine guests since 2026-09-01.

**Why it matters.** Two of its properties have already caused faults. The scope of a VM backup lives
in the guest config rather than in the backup job, so a passthrough disk without `backup=0` drags an
entire array into the target. And because it reads through the container's map, a path the container
cannot read is a path the backup cannot read.

## WAL (write-ahead log)

**What it is.** A journal a database writes changes into before applying them to the main data file,
so a crash mid-write leaves a recoverable record. SQLite in WAL mode keeps it beside the database as
`-wal`, with a shared-memory index as `-shm`. A checkpoint folds the contents back into the main
file.

**Here.** The retired Vaultwarden database looked like a textbook case and was not. Its main file
had an mtime of February beside a 57 KB `-wal` written in June, which reads like four months of
stranded transactions. `PRAGMA wal_checkpoint(TRUNCATE)` returned zero frames: the log was empty and
the file had never been truncated. The same side files are why
[KE-19](../homelab-server-architecture/docs/platform/known-errors.md#ke-19) excluded them from the SnapRAID array.

**Why it matters.** A log's size and timestamp say nothing about whether it holds data, because the
file is not truncated when its frames are checkpointed. A stale allocation and a real backlog look
identical from the filesystem, and only the database can tell them apart. The consistent set is the
main file together with its side files at one instant, which is why a live copy needs the online
backup API or a stopped writer.

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

## wildcard bind

**What it is.** A listening socket bound to "every address" rather than to one: `0.0.0.0` for IPv4,
`[::]` for IPv6, and printed by `ss` as `*:<port>` when it covers both. A specific bind names one
address, such as a node's Tailscale IP.

**Here.** The platform's binding rule forbids it: services bind the Tailscale address or loopback,
never the LAN. Instances found and fixed include sshd, the hypervisor's `node_exporter` and
`postgres_exporter`; the most recent is Debian's packaged exporter on lxc260, `*:9100`, measured
2026-09-24. On Linux a wildcard bind and a specific bind on the same port conflict, so whichever
starts first takes the port and the other fails with `EADDRINUSE`.

**Why it matters.** A wildcard listener is reachable from every network the node is attached to,
including the untrusted LAN, and at boot it usually wins the race against a correctly gated service.
Check with `ss -ltnp` and read column four.

## WOPI

**What it is.** Web Application Open Platform Interface, the protocol a document editor uses to fetch
and save a file held by another system. The editor is the client; the file's owner is the host.

**Here.** How Collabora reaches Nextcloud's files. `richdocuments` sets `wopi_url` to a `proxy.php`
endpoint on Nextcloud's own web server, so the editing traffic goes through Apache rather than
straight to the editor's port.

**Why it matters.** It explains a listener that looks worse than it is: `coolwsd` binds `*:9983`,
and nothing is supposed to reach it there, because every request arrives through the proxy. The bind
is still wrong by this platform's rule - it is simply not the hole it appears to be.
