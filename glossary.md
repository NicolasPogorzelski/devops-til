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

## ADB (Android Debug Bridge)

**What it is.** Android's remote-control channel: a client on the PC talks to a daemon on the
device over USB or TCP (port 5555 for network debugging) and gets a shell, log access
(`logcat`), screenshots (`screencap`) and file transfer. The first connection from a new PC
must be approved on the device's screen; the PC's key is then remembered.

**Here.** The Nvidia Shield that receives the game stream. Enabled under Developer options ->
Network debugging, installed on Bazzite with `brew install android-platform-tools`. It turned
the Shield into a second measuring point for
[game streaming stutter](applications/game-streaming-stutter.md): interface counters, UDP
errors, Moonlight's log and its performance overlay.

**Why it matters.** Network debugging gives every approved PC on the LAN a full shell on the
device. Switch it off when the diagnosis is done. As a technique, it is the difference between
guessing about the far end of a pipeline and measuring it.

## air gap

**What it is.** Keeping a copy off any network path that could reach it, usually by physically
disconnecting the medium.

**Here.** A disk kept at a second location, recorded in
[data classification](../homelab-server-architecture/docs/platform/data-classification.md), is a real air gap: off site,
disconnected, and of unknown age between visits.

**Why it matters.** Nothing on a network can reach it, which is the strongest guarantee available.
The weakness is that a person has to perform it, and this one is refreshed only when its owner
visits that location. An air gap with no cadence has an unknown age between refreshes, so it works
as a last resort and not as a planned control. That gap is most of the argument for paying for an
off-site target that can be scheduled.

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

## any_errors_fatal (Ansible)

**What it is.** A play keyword. Without it, a host that fails a task drops out of the run and the
other hosts carry on; with it, the first failure on any host ends the play for every host, and a
host marked failed takes part in no later play.

**Here.** `preflight.yml` sets it. Its checks run once, on the control node, but they are attributed
to a single host of the play, so without this keyword a refusal would stop that one host and let the
rest of the fleet go on to the playbook proper.

**Why it matters.** A gate that fails "for one host" is not a gate. The keyword is what turns one
refused check into a run that deploys nothing.

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

## ARP spoofing

**What it is.** On an Ethernet segment, a machine finds the hardware address behind an IP address
by asking with ARP and believing whatever answer arrives. Any device on the segment can answer for
an address that is not its own and receive the traffic meant for it.

**Here.** It is why the LAN exception in the [SMB binding decision](../homelab-server-architecture/docs/decisions/smb-bind-and-lan-access.md) counts as a residual risk:
`smb_guard` on vm102 admits port 445 from two LAN source addresses, and a device on the home LAN
that claims one of them passes that filter. It still needs a Samba account's password.

**Why it matters.** It is the concrete reason an IP address is not an identity. A filter on source
addresses holds against devices that play by the rules; a control that has to hold against one
that does not needs a key, which is what WireGuard and Tailscale provide.

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

## build provenance

**What it is.** A signed record of how an artefact was produced: which source commit, which build
system, which steps and inputs. SLSA defines its format, and it is published next to the artefact as
an attestation.

**Here.** Nothing is built on this platform; the question is only whether upstream images publish
provenance that `sbom.yml` could check alongside a signature.

**Why it matters.** A signature says who released an artefact; provenance says what went into it.
The two together are what lets a verifier refuse an image that was built from a modified source or
on an unexpected builder.

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

## CNCF (Cloud Native Computing Foundation)

**What it is.** The Linux Foundation project that hosts Kubernetes and most of the tooling around it
- Prometheus, containerd, Falco, OPA among them - and grades projects as sandbox, incubating or
graduated.

**Here.** Prometheus, the platform's monitoring core, is a graduated CNCF project, and so is
containerd underneath Docker.

**Why it matters.** The maturity level is a quick, independent signal of how widely a tool is used
and maintained, which is useful when choosing between tools during the Kubernetes track.

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

## compositor

**What it is.** The part of a Wayland desktop that owns the screen: it takes the images every
application renders, combines them into one frame per display refresh, and hands that frame to
the kernel for output. On GNOME it is Mutter, inside `gnome-shell`.

**Here.** On the gaming PC, GNOME's compositor drives both the desk monitor and the streaming
dummy plug. When it misses a refresh, every application on that output misses it too - which
is why a trivial `vkcube` stuttered on the dummy plug more than the game did
([game streaming stutter](applications/game-streaming-stutter.md)).

**Why it matters.** Frame timing problems that affect every program on one output belong to the
compositor or something competing with it, not to the programs. Test with a known-trivial
client before tuning an application.

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

## CPU type and x86-64 levels (Proxmox)

**What it is.** The CPU model a virtual machine is shown, set per VM in Proxmox (`cpu:`). The
generic levels `x86-64-v2`, `-v3` and `-v4` each promise a fixed set of instruction extensions, so a
VM can move between hosts of different generations; `host` passes the physical CPU through as it is.
`-v2` stops before AVX2, `-v3` includes it.

**Here.** vm102 runs `x86-64-v2-AES`, measured 2026-10-01. The Ryzen 2600X underneath supports
AVX2, and there is one host, so the portability the generic level buys is not used.

**Why it matters.** Software picks its fastest code path from the extensions it sees. WireGuard's
ChaCha20-Poly1305, which Tailscale runs in user space, has an AVX2 path; behind `-v2` it falls back to
a slower one. It did not limit the 1 GbE ingress test, where neither vCPU saturated, but it would at
2.5 GbE.

## CrowdSec

**What it is.** An open-source intrusion prevention system: agents parse logs for attack patterns
(SSH brute force, HTTP scanning), and "bouncers" block the offending address, with block lists
shared across all participants.

**Here.** Not deployed. The platform has no public ingress and SSH is key-only, so the attack
surface CrowdSec watches barely exists; it becomes relevant the moment the off-site VPS gets a
public address.

**Why it matters.** It is the modern replacement for fail2ban (the long-standing tool that bans an
address after repeated failed logins in a log file) and the usual first control on any host facing
the internet. On a machine reachable only through the tailnet it would mostly count noise.

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

## delegate_to and run_once (Ansible)

**What it is.** Two task keywords. `delegate_to: localhost` executes the task on another machine
than the host it is being run for, here the control node itself. `run_once: true` executes it for
the first host of the play only and shares the result with the others.

**Here.** Together, on a block in `preflight.yml`, since 2026-09-25: the play targets `all`, and the
git checks run exactly once on lxc250 however many hosts `--limit` leaves in the play.

**Why it matters.** It is how a play can depend on the control node without targeting it. A play
aimed at `localhost` is removed by any limit that does not name it; a play aimed at `all` with
delegated tasks cannot be.

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

## DERP relay and direct connection (Tailscale)

**What it is.** Two ways a packet between two tailnet nodes can travel. A direct connection is a
WireGuard tunnel between the two nodes' own addresses; DERP (Designated Encrypted Relay for Packets)
is a relay server run by Tailscale on the internet, used only while no direct path can be built.
The traffic stays end-to-end encrypted either way; what changes is the route and the speed.

**Here.** `tailscale ping storage` from the admin desktop answers `via <lan-ip>:41641 in 1ms`, which
is a direct connection over the home LAN. Measured on 2026-10-01, an SMB upload over that path
reached about 95 MB/s, so the internet uplink plays no part in media ingress.

**Why it matters.** It decides whether a transfer between two machines in the same room runs at LAN
speed or at the speed of the internet connection twice over. A relayed path is the first thing to
check when a tailnet transfer is unexpectedly slow, and `tailscale ping` shows it in one line.

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

## drop-in (systemd)

**What it is.** A file in `<unit>.d/*.conf` next to a unit that adds to or overrides single
settings of that unit without editing the unit file itself. systemd merges them in order;
`systemctl cat <unit>` shows the result, and `systemctl daemon-reload` makes a new drop-in
take effect.

**Here.** The Sunshine user unit on the gaming PC carries two: `homebrew-env.conf`
(environment for the Homebrew install) and `reset-desk-state.conf`, which restores the desk
monitor and MangoHud limit on every start
([game streaming stutter](applications/game-streaming-stutter.md)). The same mechanism is used
for service overrides throughout the homelab ([systemd Basics](linux/systemd-basics.md)).

**Why it matters.** A drop-in survives when the package replaces the unit file, and removing it
is one `rm` plus a reload. Editing the vendor unit in place is lost on the next upgrade.

## eBPF

**What it is.** Extended Berkeley Packet Filter: a way to load small, verified programs into the
running Linux kernel that react to events - system calls, network packets, function entries -
without a kernel module.

**Here.** Not used deliberately. It is how Falco, Cilium and modern profilers work, and it needs the
host kernel, so an unprivileged LXC cannot load programs.

**Why it matters.** It has become the standard way to observe and secure Linux at runtime with
little overhead, and most current container security and networking tools are built on it.

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

## exit node (Tailscale) and Mullvad

**What it is.** An exit node is a tailnet device that forwards a client's internet traffic, so the
client appears on the internet with the exit node's address. Tailscale also sells access to
Mullvad's VPN servers as exit nodes, enabled per device with the `mullvad` node attribute.

**Here.** Five devices carry the attribute, listed in
[tailscale-acl.md](../homelab-server-architecture/docs/platform/tailscale-acl.md#node-attributes).
Tailscale's own exit nodes would need a grant to `autogroup:internet`; Mullvad worked without one,
measured on the admin desktop on 2026-09-26.

**Why it matters.** While an exit node is active, a device may lose its path into the home network
unless LAN access is allowed in the client, which is why a streaming box that uses Mullvad and
Jellyfin is a decision rather than a default.

## Falco

**What it is.** A runtime security tool, hosted by the
[CNCF](#cncf-cloud-native-computing-foundation), that watches kernel system calls, via
[eBPF](#ebpf), and raises an alert when a container or process does something its rules call
suspicious: a shell spawned in a container, a write below `/etc`, an unexpected outbound connection.

**Here.** Not deployed. It needs the host kernel, so on this platform it could only run on the
hypervisor or in the VMs, never inside an unprivileged LXC - the same limit the `auditd` exercise
hit.

**Why it matters.** It is detection rather than prevention, and it is the standard answer to "how
would you know a container was compromised". Relevant for the Kubernetes track, where it is common.

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

## FIDO2, WebAuthn and passkeys

**What it is.** FIDO2 is the standard for signing in with a hardware-backed key pair instead of a
shared secret; WebAuthn is its browser API; a passkey is a FIDO2 credential that a password manager
or phone can sync. The private key never leaves the authenticator, and the signature is bound to the
site's origin.

**Here.** Not used on the platform. Authelia, planned in the
[identity decision](../homelab-server-architecture/docs/decisions/identity-before-terraform.md),
supports WebAuthn as a second factor and passkeys as a login method.

**Why it matters.** Origin binding makes it phishing-resistant: a look-alike site receives a
signature it cannot use. That is the property one-time codes lack, and why it is what enterprise and
government guidance now asks for on administrative accounts.

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

## frame pacing

**What it is.** How evenly frames are delivered in time, as opposed to how many arrive per
second. 60 FPS at a steady 16.7 ms per frame and 60 FPS alternating 13 ms and 20 ms show the
same average and look completely different.

**Here.** A game streamed from the gaming PC showed "60 FPS" in every overlay while a per-frame
MangoHud log showed a third of frames too early and a quarter too late. A limiter fixed it
([game streaming stutter](applications/game-streaming-stutter.md)).

**Why it matters.** Averages are computed over windows longer than the problem. A single slow
frame every few seconds is invisible in a one-second FPS counter and obvious to a viewer. Look
at the distribution - per-frame logs, percentiles - before trusting a rate.

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

## GGUF

**What it is.** The single-file model format of llama.cpp: weights, tokenizer and metadata in one
file, usually already quantized. A vision model comes as two files, the model and an `mmproj`
projector that turns an image into tokens the model can read.

**Here.** Both inference backends load GGUF files from a models directory, one subdirectory per
model with its projector beside it ([LLM inference](../homelab-server-architecture/docs/services/llm-inference.md)). Files are checked against the SHA-256
Hugging Face publishes before they are used.

**Why it matters.** A model is a file with a checksum, not an entry in a tool's private registry.
It can be copied, verified, moved to another disk and managed by Ansible like any other artifact.

## GitOps

**What it is.** Running infrastructure so that a Git repository is the declared desired state and an
agent continuously makes the running system match it, instead of a person running an apply. Argo CD
and Flux are the common agents.

**Here.** Not practised. The control node applies playbooks from its working tree when somebody runs
them, and the weekly drift sweep only reports divergence; it does not correct it.

**Why it matters.** It turns drift correction from a report into a loop and makes every change
reviewable as a commit. It is the default deployment model in Kubernetes environments.

## GTT (Graphics Translation Table)

**What it is.** The part of system RAM that an AMD GPU can map and use as if it were its own
memory, over PCIe. The kernel reports it per process next to VRAM, in `/proc/<pid>/fdinfo/*`
(`drm-total-vram`, `drm-total-gtt`).

**Here.** Used on 2026-09-29 to prove that the 27B model on the admin desktop sits entirely in
VRAM: 15.5 GiB VRAM, 93 MiB GTT, the latter being ordinary transfer buffers
([LLM inference](../homelab-server-architecture/docs/services/llm-inference.md)).

**Why it matters.** When VRAM runs out, a Vulkan driver can place the overflow in GTT silently.
The model still works, only several times slower, and no log line says why. Reading `fdinfo` turns
a guess into a measurement.

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

## hairpinning (NAT loopback)

**What it is.** Traffic between two devices in the same network that is sent to the router's public
address and turned back into the network by the router, instead of going straight from one device
to the other.

**Here.** It does not happen on this platform. Tailscale nodes on the same LAN learn each other's
local addresses through [NAT traversal](#nat-traversal) and connect directly, so tailnet traffic
between them never reaches the router's public side.

**Why it matters.** Where it does happen, a local transfer is capped by the router's NAT throughput
and can break outright on routers that do not support it, which is a common reason for a service
that works from outside and fails from inside the same home network.

## Happy Eyeballs

**What it is.** The client behaviour (RFC 8305) of trying IPv6 and IPv4 for the same name in quick
succession and keeping whichever connects first, so a broken IPv6 path costs a fraction of a second
instead of a timeout.

**Here.** It decides what happens if Jellyfin stops listening on IPv6: MagicDNS returns both an IPv4
and an IPv6 tailnet address for `gpu-vm`, and a client that implements Happy Eyeballs falls back to
IPv4 silently. One that does not, as some TV apps do not, waits for the IPv6 attempt to time out.

**Why it matters.** It is why removing an address family looks harmless in a browser and can still
break an embedded client. The fallback is a property of each client, not of the server.

## HDMI dummy plug

**What it is.** A small plug in a GPU output that pretends to be a monitor: it reports display
modes to the graphics driver, so the desktop can run at a resolution and refresh rate no
physical screen is showing.

**Here.** The gaming PC streams at 4K from a dummy plug on `HDMI-1`. It is enabled in every
layout (portal capture is bound to it): 60 Hz as an invisible second monitor at the desk,
120 Hz HDR while streaming, with games capped at 60 FPS. It has no [VRR](#vrr-and-vsync).

**Why it matters.** A fixed-rate display without VRR exposes every uneven frame, which a VRR
desk monitor hides. It is also a physical dependency: a plug in the wrong port made every
stream fail to start, because the prep command targeted a connector with nothing attached.

## Homebrew pin

**What it is.** `brew pin <formula>` excludes a formula from `brew upgrade` and blocks its
uninstall until `brew unpin`. The pin records *that* a version was frozen, not *why*.

**Here.** On Bazzite, command-line tools the image does not ship come from Homebrew. The
`sunshine-beta` formula had been pinned at setup because Vulkan encoding was needed. Months
later the stable release carried that feature, a security fix, and no crash on session end -
and the pin was the only reason the crashing version was still installed
([game streaming stutter](applications/game-streaming-stutter.md)).

**Why it matters.** A pin is a decision with an expiry date. Write the reason next to it, so
the next reader can check whether it still holds. Same failure class as a stale reference in
[Tailscale Exit Nodes](networking/tailscale-exit-nodes.md).

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

## host-only bridge

**What it is.** A Linux bridge on the hypervisor with no physical network port attached
(`bridge-ports none`). Guests given a virtual NIC on it can reach each other and the host, and
nothing else: no frame on it ever reaches the wire, and no device on the LAN can send one to it.

**Here.** Not built. It is the candidate for carrying SMB between the Proxmox host, vm100 and vm102
instead of the LAN, an alternative to step 2 of the [SMB binding decision](../homelab-server-architecture/docs/decisions/smb-bind-and-lan-access.md), which moves the
same mounts onto Tailscale. On Proxmox it is a `vmbr` stanza in `/etc/network/interfaces` without
a `bridge-ports` member.

**Why it matters.** It takes the LAN out of the path by construction rather than by filter, and it
adds no daemon the mount would have to wait for at boot. What it does not give is identity:
inside the bridge, addresses are still only addresses, which is acceptable because only the
hypervisor decides what attaches to it.

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

## identity provider (IdP)

**What it is.** The service that proves who a user is and tells other applications the answer. The
applications stop checking passwords themselves and trust a signed statement from the provider
instead. It usually reads its users from a directory such as LDAP.

**Here.** Planned, not built: Authelia on a new node, reading users from `lldap`, scheduled for
2026-09-25 to 2026-09-27
([decision](../homelab-server-architecture/docs/decisions/identity-before-terraform.md)). Until then
every service keeps its own user table.

**Why it matters.** It concentrates trust. One place to add or remove a person, one place where a
stolen admin password opens everything, and one service that must be up for anyone to sign in -
which is why every application here keeps a local administrator that does not depend on it.

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

## KMS capture

**What it is.** Screen capture that reads the picture straight from the kernel's display
subsystem (Kernel Mode Setting, the part of the graphics driver that drives outputs), below
the desktop [compositor](#compositor). It needs `cap_sys_admin` on the capturing binary.

**Here.** Sunshine's capture method on the gaming PC until the stutter diagnosis; now kept only
as a rollback (`sunshine-display-mode kms-desk`). It survives display switching because it does
not care which monitor was active at startup - but it samples on Sunshine's own clock and
converts on the same GPU as the compositor, and measurably made GNOME miss refreshes
([game streaming stutter](applications/game-streaming-stutter.md), cause 5).

**Why it matters.** It works everywhere, which is why tools default to it - but it bypasses the
compositor instead of cooperating with it. Reading a buffer the compositor is about to reuse,
on an unsynchronised clock, is a contention source that no log reports.

## KV cache

**What it is.** The memory in which a language model keeps the intermediate results (keys and
values) of every token already in the context, so it does not recompute them for each new token.
It grows with the context length and is reserved when the model loads.

**Here.** Both backends store it as `q8_0` (8-bit) instead of 16-bit, which roughly halves it.
That is what fits 64K of context next to the 27B model on a 20 GB card
([LLM inference](../homelab-server-architecture/docs/services/llm-inference.md)).

**Why it matters.** Model size alone does not say whether a model fits. Weights plus KV cache
plus the desktop's own use must stay under the VRAM, and the KV cache is the part that the context
setting controls.

## lateral movement

**What it is.** An attacker who has taken one system using it as a base to reach the next, instead
of attacking each target from outside.

**Here.** Until 2026-09-26 the policy let every tier1 service reach every other on all ports, and
the control node shared a tag with the operator's phone and workstations. Both paths were closed in
the rebuild described in
[tailscale-acl.md](../homelab-server-architecture/docs/platform/tailscale-acl.md).

**Why it matters.** Most intrusions start on the weakest system, not the most valuable one. What
limits the damage is how little the first foothold can reach.

## LD_LIBRARY_PATH

**What it is.** An environment variable listing directories the dynamic linker searches for
shared libraries *before* the system defaults (`man 8 ld.so`). Every child process inherits it,
including programs that never asked for it.

**Here.** The Sunshine user unit on the gaming PC sets it to Homebrew's `lib/`. `gdctl` runs on
`/usr/bin/python3`, which then loaded Homebrew's `libpython3.14.so` and could not import the
system `gi` module - the display-restore safety net failed silently for weeks behind a
fail-open `-`. The fix drops the variable for that one call: `env -u LD_LIBRARY_PATH gdctl`
([game streaming stutter](applications/game-streaming-stutter.md)).

**Why it matters.** It is set for one program and silently changes every program that program
starts. When a tool works in a terminal but not from a service, compare the environments -
`env` in both, `ldd` on the failing binary.

## LDAP (Lightweight Directory Access Protocol)

**What it is.** A protocol for reading and searching a directory of users and groups, organised as a
tree of entries with a distinguished name each (`uid=alice,ou=people,dc=example,dc=com`). An
application signs a user in by binding to the directory with the user's name and password; if the
bind succeeds, the password was right.

**Here.** Planned as `lldap`, a small LDAP server with a web interface, on the identity node. The
clients that use it directly are the ones that cannot show a browser for OIDC - Jellyfin's TV apps -
and Calibre-Web, which has LDAP and no generic OIDC. Nextcloud ships `user_ldap`, installed and
disabled, measured 2026-09-24.

**Why it matters.** The application sees the password. That is acceptable for a trusted service on
the tailnet and is the reason browser applications use OIDC instead, where the password is typed
only into the provider.

## least privilege

**What it is.** Giving every identity - a person, a device, a service - exactly the rights its task
needs, and nothing it might need some day.

**Here.** The rule behind the 2026-09-26 policy: each device reaches the services its owner uses, by
host and port, and the operator phone reaches the hypervisor only for its web interface, meant to be
backed by a Proxmox user that may do nothing but shut down
([tailscale-acl.md](../homelab-server-architecture/docs/platform/tailscale-acl.md)).

**Why it matters.** It decides the size of the damage when something is compromised. A stolen phone
that can only switch a server off is an inconvenience; one that holds full administrative reach is
an incident.

## limit (ansible-playbook --limit)

**What it is.** A command-line pattern that narrows the hosts of a run, for example
`--limit lxc260`. It intersects with the `hosts:` line of every play in the playbook, including
imported ones.

**Here.** Used to roll a change out one node at a time. Until 2026-09-25 it also removed the
preflight gate, which targeted `localhost`; Ansible printed `skipping: no hosts matched` and ran the
rest of the playbook from whatever tree the control node held.

**Why it matters.** A limit is read as "only these nodes", but it applies to every play, and a play
it empties is skipped without an error.

## linger (systemd user manager)

**What it is.** `loginctl enable-linger <user>` starts that user's systemd instance at boot and
keeps it running without a login. Without it, user units start only when the user logs in and
stop when the last session ends.

**Here.** Enabled for `admin` on the Bazzite desktop. The `llama-server` Quadlet is a user unit,
so linger is what makes the primary inference backend available after a reboot with nobody at the
machine. It was first switched on for an earlier Whisper experiment and kept for this reason.

**Why it matters.** It looks like leftover configuration once its original purpose is gone.
Switching it off breaks nothing visible on the desktop and silently takes the backend offline
until the next login.

## llama.cpp and llama-server

**What it is.** llama.cpp is the C/C++ inference engine behind most local LLM tools, with
backends for CUDA, Vulkan, ROCm and the CPU. `llama-server` is its built-in HTTP server with an
OpenAI-compatible API. In router mode (`--models-dir`) it starts without a model, loads one on the
first request that names it, and unloads it after an idle period (`--sleep-idle-seconds`).

**Here.** It replaced Ollama on both inference nodes on 2026-09-29, the official container image
in the same build on each ([LLM inference](../homelab-server-architecture/docs/services/llm-inference.md)). Measured on the same hardware and model:
40.6 against 26.1 tokens/s on the desktop.

**Why it matters.** Ollama wraps a similar engine in a convenience layer and picks up its
optimisations late. The wrapper cost 35 % on the AMD card and 9 % on the NVIDIA card, so which
tool is "best" depended on the hardware and had to be measured.

## LLMNR and mDNS

**What it is.** Link-Local Multicast Name Resolution and multicast DNS: two protocols that resolve a
name by shouting the question to the whole local segment when DNS has no answer. Neither
authenticates the reply.

**Here.** `systemd-resolved` enables both by default. lxc250 answered on port 5355 after the
`nsswitch` change until it was closed during the September block, recorded in the
[remediation plan](../homelab-server-architecture/docs/platform/remediation-plan.md).

**Why it matters.** Any host on the same segment can answer a failed lookup and receive the
connection, including credentials offered to it - a standard step in internal penetration tests,
automated by the Responder tool, which answers every such lookup and collects the credentials
offered to it. On a node holding the vault password it is a direct path to it.

## local mailer (Postfix and /etc/aliases)

**What it is.** A mail server on the machine itself, which delivers mail addressed to local users
such as `root`. Postfix looks up where `root` should go in `/etc/aliases`, compiled into
`/etc/aliases.db` by `newaliases`.

**Here.** On the Proxmox host. Cron mails every job's output to root, and so does smartd. Measured
2026-09-25: `/etc/aliases.db` does not exist, so every such message is deferred with
`alias database unavailable`; 29 were queued, visible with `mailq`.

**Why it matters.** Output sent by mail looks like reporting, but when nothing delivers it nobody
sees it. The KE-26 read-back failure was found in that queue rather than in the journal.

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

## machine sharing (Tailscale)

**What it is.** Offering one device of your tailnet to a user of another tailnet. The recipient
accepts an invitation in their own tailnet and reaches only that device, still subject to the
sharer's policy.

**Here.** Since 2026-09-26 one external user reaches Jellyfin, Audiobookshelf and Nextcloud this way
instead of as a member of the tailnet
([tailscale-acl.md](../homelab-server-architecture/docs/platform/tailscale-acl.md)).

**Why it matters.** It keeps external people's devices out of your network entirely: they cannot add
devices, and a rule written too broadly cannot reach them. Rights attach to the person, so
per-device limits are not possible this way.

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

## MFA and TOTP

**What it is.** Multi-factor authentication requires a second proof besides the password. TOTP
(time-based one-time password) is the common form: an authenticator app derives a six-digit code
from a shared secret and the current time.

**Here.** Planned for the Proxmox user of the operator phone, so that knowing its password alone
does not switch the host off. Phishing-resistant forms are described under
[FIDO2, WebAuthn and passkeys](#fido2-webauthn-and-passkeys).

**Why it matters.** A leaked password stops being enough. TOTP codes can still be phished in real
time, which is where passkeys go further.

## microburst

**What it is.** A burst of packets sent at full line rate for a few milliseconds, even though
the average rate is low. Where a link steps down in speed (2.5 Gbit/s in, 1 Gbit/s out), the
device in between must buffer what it cannot forward yet; a small buffer overflows and drops
the tail of the burst.

**Here.** Sunshine sends each video frame as one burst. The gaming PC's 2.5 Gbit/s port fed a
path that ended at a 1 Gbit/s switch port to the Shield: about 4.7 % of packets vanished with
no error counter on either network card. Limiting the PC to 1 Gbit/s made the loss exactly
zero ([game streaming stutter](applications/game-streaming-stutter.md)).

**Why it matters.** Average bandwidth (150 Mbit/s here) says nothing about bursts, and a switch
dropping on overflow is behaving correctly, so nothing logs it. Count packets at both ends of
the same interval; the difference is the only evidence.

## mtime

**What it is.** The modification time the filesystem stores for every file: the moment its content
was last written. `stat -c %y <file>` prints it, and `ls -l` shows it in short form. Reading or
copying a file does not change it; rewriting it with the same content does.

**Here.** The quick check for whether an Ansible change reached a node: if the template's last
commit is newer than the mtime of the file the role rendered, the playbook has not run since the
change. See [Documentation-vs-Reality Audits](operations/doc-reality-audit.md#merged-is-not-applied-2026-09-30).

**Why it matters.** It answers "when did this file last change" without a log. It cannot answer
"is the content current": a role that renders identical content may leave the time untouched, so a
date comparison only narrows the question, and `--check --diff` settles it.

## mTLS (mutual TLS)

**What it is.** TLS in which both sides present a certificate, so the server authenticates the
client as well as the other way round.

**Here.** Not used. WireGuard, underneath Tailscale, already authenticates both ends of every
connection by node key, which is why the journal upload runs plain HTTP
([ansible.md](../homelab-server-architecture/docs/platform/ansible.md)).

**Why it matters.** It is how service-to-service authentication works where there is no overlay
network - in Kubernetes [service meshes](#service-mesh) and between cloud services - and is the
comparison the plain-HTTP choice here is meant to prompt.

## NAT traversal

**What it is.** The set of techniques two devices behind address translation use to reach each
other directly: each learns the addresses at which it can be reached, they exchange them through a
coordination service, and both send packets at the same time until one pair of addresses works.

**Here.** Tailscale does this for every pair of nodes. Inside the home LAN the local address wins
immediately, which is why the admin desktop reaches vm102 over a
[direct connection](#derp-relay-and-direct-connection-tailscale) rather than through a relay.

**Why it matters.** It is what lets an overlay network avoid both open ports on the router and a
central relay for every byte. When it fails, Tailscale falls back to DERP and keeps working, only
slower, so the failure shows up as a performance problem rather than an outage.

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

## OIDC (OpenID Connect)

**What it is.** A sign-in protocol built on OAuth 2.0, the standard for handing an application a
limited token instead of a password. The application redirects the browser to the identity provider,
the user signs in there, and the browser returns with a code the application exchanges for a signed
ID token that names the user. The provider publishes its endpoints and keys in a discovery document
at `/.well-known/openid-configuration`.

**Here.** Planned with Authelia as the provider, for Grafana, OpenWebUI, Paperless-ngx and
Audiobookshelf. It needs no reverse proxy, which matters because services here are published by
`tailscale serve` on their own nodes.

**Why it matters.** The application never sees the password, and a session can be revoked in one
place. The price is that it needs a browser: a client that only knows username and password fields,
like a TV app, cannot follow the redirect and needs LDAP instead.

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

## OpenSSF Scorecard

**What it is.** An automated check from the Open Source Security Foundation that grades a repository
on supply-chain practices: pinned dependencies, branch protection, token permissions in workflows,
signed releases, dependency update tooling.

**Here.** Not run. The repository already meets several of its checks - SHA-pinned actions, a branch
ruleset, Dependabot - and would lose points on the two tag-pinned actions in `sbom.yml` and on
workflows that declare no `permissions:` block.

**Why it matters.** It turns "we follow good practice" into a score an outsider can read, and it is
available as a GitHub Action.

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

## Policy-as-Code

**What it is.** Writing rules about configuration as code that a machine evaluates, instead of as
prose somebody has to remember. Common engines are OPA (Open Policy Agent) with its rule language
Rego, Conftest (OPA applied to configuration files) and Kyverno (policies written as Kubernetes
resources).

**Here.** `validate-repo.sh` is a hand-built form of it: 44 checks that refuse a commit. The
Tailscale ACL `tests` block is another.

**Why it matters.** It is how an organisation enforces rules across many repositories and teams, and
the natural next step once Terraform plans exist to check.

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

## public key pinning

**What it is.** Accepting a TLS server only if its certificate carries one specific public key,
given as a hash, instead of (or in addition to) checking that a trusted CA signed it for the
requested host name. `curl --pinnedpubkey sha256//<base64>` does this and keeps checking the pin
even under `-k`, which switches off the CA and host name checks.

**Here.** `sunshine-session-watch` sends the Sunshine web UI password to
`https://localhost:47990`. Sunshine's certificate is self-signed for another name, so normal
verification fails; the script computes the pin from Sunshine's own `cacert.pem` at run time
([game streaming stutter](applications/game-streaming-stutter.md)).

**Why it matters.** `-k` alone authenticates nobody: any process that binds the port first while
the real service is down receives the credential. A pin restores authentication without a CA, and
breaks loudly (curl exit 90) instead of leaking when the key changes.

## Public Suffix List

**What it is.** A list, maintained at `publicsuffix.org`, of domain suffixes under which unrelated
parties register names - `com`, `co.uk`, and private entries such as `github.io`. Browsers refuse to
let a site set a cookie for a listed suffix, so `a.github.io` cannot plant a cookie on `b.github.io`.

**Here.** `ts.net` is on it, as an entry submitted by Tailscale, measured 2026-09-24. Every MagicDNS
name on this tailnet sits under it. A cookie can therefore be scoped to `<tailnet-id>.ts.net` at
the widest, never to `ts.net`, and Authelia refuses the latter at startup. The planned provider scopes
its cookie to its own host name, narrower than it has to.

**Why it matters.** It sets the upper bound for sharing a session between hosts. On a hosting domain
that nobody has listed, one customer could set cookies for every other customer's site, which is
the problem the list exists to close.

## Quadlet (Podman)

**What it is.** A way to declare a Podman container as a systemd unit: a `.container` file in
`~/.config/containers/systemd/` (or `/etc/containers/systemd/`) is translated into a regular
service at `daemon-reload`. `/usr/libexec/podman/quadlet -dryrun -user` shows the generated unit
without starting anything.

**Here.** The `llama-server` backend on the Bazzite desktop is a rootless Quadlet, source in
`snippets/bazzite/` of the homelab repository.

**Why it matters.** Restart on failure, start at boot, logs in the journal and dependencies all
come from systemd rather than from a container daemon, and the container runs as the user, not as
root. On an image-based OS it needs nothing layered onto the image.

## quantization (Q4_K_M, Q3_K_XL)

**What it is.** Storing a model's weights with fewer bits than it was trained with, typically 3 to
8 instead of 16. The name encodes the scheme: `Q4_K_M` is 4-bit in llama.cpp's K-quant family,
medium variant; Unsloth's `UD-Q3_K_XL` is a dynamic 3-bit mix that keeps sensitive layers at
higher precision.

**Here.** The desktop runs the 27B model in Q3 because Q4 did not fit fully on the GPU next to
the desktop's own use; vm100 runs its 9B model in Q4 ([LLM inference](../homelab-server-architecture/docs/services/llm-inference.md)).

**Why it matters.** A model that spills partly to the CPU loses far more speed than one step of
quantization loses quality. The choice is between a smaller quantization and a smaller model, not
between quality and speed.

## quorum

**What it is.** The rule a cluster uses to decide whether it is allowed to act: a majority of nodes
must be reachable. Its purpose is to prevent a split-brain, where two halves of a partitioned
cluster each believe they are in charge and both write to shared storage.

**Here.** Not applicable - a single node is trivially its own majority.

**Why it matters.** Because the *logic* is still present even where the situation is not. Under
[HA](#ha-high-availability), a node that believes it has lost quorum self-fences. On a single node
there is no genuine loss of quorum to detect, only false positives - which is the core argument for
leaving HA switched off here.

## Renovate

**What it is.** A dependency update bot comparable to Dependabot, with broader file support: Docker
Compose image tags, Ansible Galaxy requirements, pinned digests, and grouping or auto-merge rules
per package.

**Here.** Not used. Dependabot covers GitHub Actions only, and the compose images are deliberately
left out of it ([dependabot.yml](../homelab-server-architecture/.github/dependabot.yml)).

**Why it matters.** It can keep a pinned tag and its digest together and propose both at once, which
is the piece a manual pinning policy is missing.

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

## ROCm

**What it is.** AMD's GPU compute stack, the counterpart to NVIDIA's CUDA: kernel driver interface
(`/dev/kfd`), runtime and math libraries (rocBLAS and others), with per-architecture support such
as `gfx1100` for the RX 7900 series.

**Here.** Ollama's bundled ROCm 7.2.1 aborted on every model load on the Bazzite desktop after its
kernel and firmware updates, while Fedora's ROCm 7.1.1 ran. Even working, it generated tokens 21 %
slower than Vulkan on that card, so the desktop uses Vulkan ([LLM inference](../homelab-server-architecture/docs/services/llm-inference.md)).

**Why it matters.** ROCm ships its own user-space runtime inside each application or image, so its
compatibility with the host kernel is decided per image and can break with an OS update that
touched nothing in the application.

## RTC and rtcwake

**What it is.** The RTC (real-time clock) is the battery-backed clock on the mainboard that keeps
time while the machine is off, and it can hold one alarm that powers the machine on. `rtcwake` sets
that alarm; `-m no -t <epoch>` arms it without suspending. The kernel shows the armed time in
`/sys/class/rtc/rtc0/wakealarm`.

**Here.** `homelab-setwake.sh` on the Proxmox host arms it every night at 00:45 before the 01:00
shutdown (homelab KE-26). `rtcwake` reads the RTC and then the system clock and corrects the alarm by the
difference, so it can arm one second early when the second ticks between the two reads.

**Why it matters.** The host is off every night, and this alarm is the only thing that brings it
back. `rtcwake` exits 0 for an alarm on the wrong day, so the script reads the armed value back.

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

## SBOM (Software Bill of Materials)

**What it is.** A machine-readable list of every component inside a piece of software - packages,
versions, licences - in a standard format - SPDX (from the Linux Foundation) or CycloneDX (from
OWASP), the two formats tools exchange.

**Here.** Produced monthly for the pinned images by the `sbom.yml` workflow, as one of the four
exercises in the
[exercise-scope decision](../homelab-server-architecture/docs/decisions/exercise-scope-before-terraform.md).

**Why it matters.** When a new vulnerability is published, an SBOM answers "are we affected" without
pulling and scanning every image again. Several regulations, including the EU Cyber Resilience Act,
now require one for products.

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

## service mesh

**What it is.** A layer of proxies beside every service in a cluster that handles service-to-service
traffic: mutual TLS, retries, traffic splitting and per-request metrics, configured centrally rather
than in each application. Istio and Linkerd are the common ones.

**Here.** Not used; there is no cluster. Tailscale provides the encryption and node identity a mesh
would, at the node level rather than per service.

**Why it matters.** It is where mTLS and fine-grained service identity usually live in an enterprise
Kubernetes platform.

## SIEM and XDR

**What it is.** A SIEM (Security Information and Event Management) collects logs from many systems,
correlates them and raises security alerts. XDR (Extended Detection and Response) adds agents on the
endpoints that can also act - isolate a host, kill a process.

**Here.** Neither exists. The journal aggregation exercise collects logs centrally, but nothing
correlates them or alerts on security events.

**Why it matters.** It is the core tool of a security operations centre, and the place the "who
logged in where" question gets answered across a whole estate rather than host by host.

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

## Sigstore and cosign

**What it is.** Sigstore is a public infrastructure for signing software artefacts without managing
long-lived keys; `cosign` is its tool for signing and verifying container images. Signatures are
recorded in Rekor, a public append-only log, so a signature made in secret would be visible as
missing.

**Here.** `sbom.yml` installs cosign and verifies the images that publish a signature.

**Why it matters.** A signature proves which builder produced an image, which a tag or a digest
alone does not. Verifying it before deployment is the check that stops a tampered registry image.

## SLAAC and router advertisements

**What it is.** IPv6's way of handing out addresses without a DHCP server. The router periodically
sends a router advertisement (RA) naming the network prefix, and every host builds its own address
from that prefix (Stateless Address Autoconfiguration). With a provider prefix, that address is
globally routable.

**Here.** vm100's netplan file mentions only `dhcp4`, yet `enp6s18` carries a global `2a01:` address
and a ULA, both built from the router's RAs by `systemd-networkd` (measured 2026-10-01; the kernel's
`accept_ra` reads 0 because networkd handles RAs itself). `accept-ra: false` in netplan stops it.

**Why it matters.** A host gets a world-routable address without anyone configuring one, and every
service bound to `[::]` is listening on it. What keeps it closed then is the router's inbound IPv6
policy, a setting this repository does not control.

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

## SLSA (Supply-chain Levels for Software Artifacts)

**What it is.** A framework (pronounced "salsa") that grades how trustworthy a build is, in levels:
whether [provenance](#build-provenance) is recorded, whether it is signed, whether the build ran on
a hardened, isolated builder.

**Here.** Not applied. Nothing is built here; the platform consumes upstream images, so the question
is only whether those images carry SLSA provenance that can be checked.

**Why it matters.** It is the vocabulary in which supply-chain requirements are written, and a
[provenance](#build-provenance) attestation is what a verifier checks alongside a signature.

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

## SMB signing and encryption

**What it is.** Two protections of SMB2/3 that Samba can require per server or per share. Signing
(`server signing = mandatory`) adds a cryptographic checksum to every message, so a message altered
or injected on the way is rejected. Encryption (`smb encrypt = required`) also hides the content.
Both are keyed from the session's authentication, so they protect the transport, not access to it.

**Here.** Neither is required on vm102 today. The shares are reached over the LAN, over Tailscale,
whose WireGuard tunnel already provides both properties, and possibly later over a
[host-only bridge](#host-only-bridge), where no third party can sit on the path.

**Why it matters.** They are the way to protect SMB on a network you do not control, without
putting a tunnel underneath it. Where a tunnel or an isolated segment already does that job,
requiring them costs CPU on every read and buys little.

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

## SOPS

**What it is.** Secrets OPerationS, a tool that encrypts only the values in a YAML, JSON or env file
and leaves the keys readable, using age, PGP or a cloud key service.

**Here.** Not used; secrets in the repository are held with Ansible Vault.

**Why it matters.** A diff of a SOPS file shows which secret changed, where an Ansible Vault diff
shows only that the ciphertext changed. It is common in [GitOps](#gitops) and Terraform setups,
which is where the next track goes.

## sponge (moreutils)

**What it is.** A small utility that reads all of its input before it writes any output. `cmd |
sponge file` is the safe form of `cmd > file`, which truncates the file before the command has
produced anything.

**Here.** In the `ExecStart` of the packaged smartmon collector unit, writing `smartmon.prom`.

**Why it matters.** A textfile collector is read by node_exporter on its own schedule, so a plain
redirect exposes a window in which the file is empty or half written and the metrics simply vanish
for a scrape. Absent is not zero: a rule written as `> 0` reads an absent metric as silence rather
than as a fault.

## SSH certificates

**What it is.** Instead of listing public keys in every `authorized_keys` file, a certificate
authority signs a user's key with a validity period and a principal name, and servers trust the CA
through `TrustedUserCAKeys`.

**Here.** Not used. Access is managed by listing keys, per node, which is how a retired key stayed
authorised as root on the hypervisor after it had been removed everywhere else.

**Why it matters.** Certificates expire on their own, so a lost laptop stops being a standing
credential. Tools such as step-ca, Teleport (an access platform that brokers SSH and database
sessions) or HashiCorp Vault issue them, and Tailscale SSH offers a managed variant.

## steal time

**What it is.** The share of time a virtual CPU was ready to run but the hypervisor was running
something else. Linux in a guest reports it as `steal` in `/proc/stat` and in `top` as `st`.

**Here.** The guests hold 26 vCPUs on the host's 12 threads. During the SMB ingress test on
2026-10-01, vm102 read 0 to 0.5 % steal, sampled every second, so the overcommit cost nothing.

**Why it matters.** It is the one number that tells you whether [vCPU overcommit](#vcpu-overcommit)
is hurting a guest. High CPU inside a guest with zero steal is the guest's own load; rising steal
means the host is the bottleneck and adding vCPUs to the guest makes it worse.

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

## Sunshine and Moonlight

**What it is.** A self-hosted game streaming pair. Sunshine runs on the host, captures the
screen, encodes it as video and sends it over the network; Moonlight is the client that
decodes and shows it, and sends controller input back. The protocol is the one Nvidia
GameStream used.

**Here.** Sunshine runs as a systemd user unit on the gaming PC (Bazzite, installed from
Homebrew); Moonlight runs on the Nvidia Shield attached to the TV. Sunshine's
`global_prep_cmd` switches displays and the MangoHud FPS limit when a session starts and when
the app is closed - not on a mere disconnect, which keeps the session open for a resume
([game streaming stutter](applications/game-streaming-stutter.md)).

**Why it matters.** The stream crosses many independent stages - game, capture, encoder,
network, decoder, display - each of which can cause stutter. The client overlay and the host
log together show which stage lost the frame.

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

## systemd credentials

**What it is.** A way to hand a secret to one service without putting it in the unit, the
environment or a world-readable file. `systemd-creds encrypt` seals it with a key bound to the
machine (and, with `--user`, to the user); `LoadCredentialEncrypted=<id>:<path>` in the unit
decrypts it at service start into a private directory that only that service sees,
named by `$CREDENTIALS_DIRECTORY`.

**Here.** The Sunshine web UI password for `sunshine-session-watch.service`, a user unit on the
gaming PC, stored as `~/.config/sunshine-session-watch/api.cred`
([game streaming stutter](applications/game-streaming-stutter.md)).

**Why it matters.** Environment variables leak into child processes and `/proc/<pid>/environ`,
and a plain file leaks into every backup. The encrypted file is useless off this machine. The
catch: it is read once, at start - a changed secret needs a `restart`, and `start` on a running
unit does nothing.

## systemd-cat

**What it is.** A small systemd tool that runs a command with its stdout and stderr connected to the
journal, under an identifier given with `-t`. `--stderr-priority=err` files stderr at error
priority. The command's exit code is passed through.

**Here.** In `/etc/cron.d/homelab-schedule` on the Proxmox host since 2026-09-25, so both
power-schedule scripts log under `homelab-setwake` and `homelab-shutdown`. Read with
`journalctl -b -1 -t homelab-setwake`.

**Why it matters.** Cron sends output by mail, and on this host mail goes nowhere (see local
mailer). The journal persists across the nightly power-off, so it is where this evidence can
actually be read.

## Tailnet Lock

**What it is.** A Tailscale feature in which new nodes must be signed by trusted keys held on your
own devices before other nodes accept them, rather than being admitted by the coordination server
alone.

**Here.** Not enabled, measured 2026-09-26 with `tailscale lock status`. Every access decision on
this platform rests on the tailnet
([tailscale-acl.md](../homelab-server-architecture/docs/platform/tailscale-acl.md)).

**Why it matters.** Without it, whoever controls the coordination server or the admin account can
add a node to the tailnet. With it, that also needs a signing key held on your own devices.

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

## toll fraud

**What it is.** Criminals using a compromised telephone account to call premium-rate or foreign
numbers they earn money from, usually at night and in large volume. The bill goes to the account
holder.

**Here.** The router's security report on 2026-09-26 showed calls abroad and to premium numbers
unblocked, on an account whose SIP signalling runs unencrypted. SIP is the protocol internet
telephony uses to set up calls.

**Why it matters.** It turns a small compromise into a direct financial loss, and blocking the call
classes nobody uses costs nothing.

## TR-069

**What it is.** A protocol through which an internet provider manages customer routers remotely:
configuration, firmware, diagnostics. The router contacts the provider's auto configuration server
(ACS).

**Here.** The router contacts its provider's ACS hourly over plain HTTP without certificate
verification, measured on 2026-09-26.

**Why it matters.** Whoever can answer in the ACS's place can reconfigure the router. Over HTTP
without verification that is anyone positioned on the path.

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

## UDP

**What it is.** The User Datagram Protocol: sends individual packets with no connection, no
acknowledgement and no retransmission. A lost packet is simply gone; anything that needs
reliability must add it on top.

**Here.** Sunshine sends the game stream over UDP. Moonlight adds forward error correction
(spare packets that let it rebuild a few lost ones) and asks for a fresh full frame when too
many are missing - visible as a hitch. On Linux and Android, `/proc/net/snmp` counts UDP
receive-buffer overflows (`RcvbufErrors`).

**Why it matters.** For live video a late packet is worthless, so UDP is the right choice -
but it means loss shows up as picture errors instead of slowdowns, and nothing on the path
reports it. Loss must be measured, not waited for.

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

## UPnP and PCP

**What it is.** Two protocols that let a program on the LAN ask the router to open a port towards
the internet by itself: UPnP IGD and the Port Control Protocol (RFC 6887).

**Here.** The router's port-share page offered to disable the per-device permission for devices that
never used it, which means some still held it on 2026-09-26. No share existed at that time.

**Why it matters.** The router's own documentation warns that malware on a permitted device can use
it to open the firewall. Allowing it per device and only where needed keeps the firewall's state
under the owner's control.

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

## VA-API and Vulkan Video

**What it is.** Two Linux interfaces to the GPU's hardware video encoder. VA-API (Video
Acceleration API) is the long-established one; Vulkan Video exposes the same hardware through
the Vulkan graphics API and is newer (on AMD's Mesa driver it needs
`RADV_EXPERIMENTAL=video_encode`).

**Here.** Sunshine on the gaming PC encodes with Vulkan Video on the RX 7900 XT, as Bazzite's
service configures it. Switching to VA-API was tried during the stutter diagnosis on a wrong
premise; it added about 3 ms host latency and changed nothing else, and was reverted
([game streaming stutter](applications/game-streaming-stutter.md)).

**Why it matters.** "Experimental" is a label, not a measurement. Compare encoders by host
processing latency with everything else held constant, not by reputation.

## vCPU overcommit

**What it is.** Giving the guests more virtual CPUs in total than the host has hardware threads. Each
vCPU is an ordinary host thread, scheduled like any other; an idle vCPU costs nothing.

**Here.** 26 vCPUs on 12 threads, measured 2026-10-01: vm100 8, lxc230 4, and two each for vm102 and
the six other containers, at a host load near 0.7.

**Why it matters.** It resembles thin provisioning, with a milder failure: when guests want more CPU
at once than the host has, they slow down and [steal time](#steal-time) rises, but nothing breaks. A
full thin pool, by contrast, returns I/O errors. The limit to watch is concurrent demand, not the sum
of the numbers.

## VEX (Vulnerability Exploitability eXchange)

**What it is.** A statement attached to an SBOM saying whether a known vulnerability actually
affects the product - "not affected, the vulnerable function is never called" - in a
machine-readable form.

**Here.** Not used. The weekly image scan reports every CVE that matches a package version, without
that context.

**Why it matters.** Most scanner findings are not exploitable where they occur, and VEX is the
standard way to record that judgement once instead of re-reading the same list every week.

## VRR and VSync

**What it is.** VSync makes the GPU wait for the display's next fixed refresh before showing a
frame, so frames never tear but must fit a fixed grid (16.7 ms at 60 Hz). VRR (Variable
Refresh Rate) lets the display wait for the GPU instead: the refresh happens when the frame is
ready, within the display's supported range.

**Here.** The desk monitor supports VRR up to 75 Hz, the streaming [dummy plug](#hdmi-dummy-plug)
does not. The MangoHud limit is therefore 72 at the desk (below the VRR ceiling) and exactly
60 while streaming ([game streaming stutter](applications/game-streaming-stutter.md)).

**Why it matters.** VRR hides uneven [frame pacing](#frame-pacing). A game that looks smooth on
a VRR monitor can stutter on any fixed-rate output - a TV, a capture device, a stream.

## Vulkan (compute) and RADV

**What it is.** Vulkan is a cross-vendor graphics and compute API. RADV is Mesa's open-source
Vulkan driver for AMD GPUs, shipped with the OS. llama.cpp can run inference on it without any
vendor compute stack installed.

**Here.** The primary inference backend on the Bazzite desktop runs llama.cpp on Vulkan/RADV:
40 tokens/s against 33 with ROCm, and it needs only the render node, not `/dev/kfd`
([LLM inference](../homelab-server-architecture/docs/services/llm-inference.md)).

**Why it matters.** The driver comes with the operating system and games already depend on it, so
it is updated and tested with the desktop instead of against it. The trade is prompt processing,
where ROCm was about 8 % faster.

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

## Wazuh

**What it is.** An open-source security monitoring platform combining a host agent, log analysis,
file integrity monitoring and vulnerability detection with a central manager - a free
[SIEM and XDR](#siem-and-xdr).

**Here.** Not deployed. The platform's nearest equivalents are the `fleet_snapshot` diff, the
`auditd` exercise and the journal aggregation.

**Why it matters.** It is what those three pieces look like assembled into one product, and a common
entry-level SIEM in small companies and security training.

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

## WPS (Wi-Fi Protected Setup)

**What it is.** A shortcut for joining a Wi-Fi network by pressing a button or entering a PIN
instead of typing the passphrase.

**Here.** Enabled on the home router, measured on 2026-09-26.

**Why it matters.** Its PIN method has a well-known design weakness, and the push-button method lets
anyone near the router join during the window. With a passphrase in place it adds reach and no
protection.

## XDG Desktop Portal (screencast)

**What it is.** A desktop service through which sandboxed or unprivileged programs ask the user
for access to things like the screen. The user picks a monitor in a consent dialog, and the
program receives that monitor's picture through PipeWire, the Linux media-routing service.

**Here.** Sunshine's capture method on the gaming PC (`capture = portal`). The grant is bound to
the chosen monitor, so the [dummy plug](#hdmi-dummy-plug) now exists in every display layout;
only the desk monitor comes and goes. The first attempt failed because the prep command
disabled the granted monitor (`RemoteDesktop Start failed`). GNOME 50 passes HDR through
(BT.2020 + PQ) ([game streaming stutter](applications/game-streaming-stutter.md)).

**Why it matters.** The compositor pushes each finished frame instead of the capturer reading
behind its back - no privileges, no clock race. The price is that consent is tied to a
monitor: anything that reconfigures displays must keep that monitor alive.

## Zero Trust

**What it is.** An architecture principle: no request is trusted because of where on the network it
comes from. Each access is authenticated, authorised against the identity and device making it, and
limited to what is needed. The reference description is NIST Special Publication 800-207, the US
standards institute's architecture document for it.

**Here.** The platform's access model: the LAN is untrusted, services bind the tailnet address, and
ACL tags decide which node may reach which port
([tailscale-acl.md](../homelab-server-architecture/docs/platform/tailscale-acl.md)). What it lacks
is the per-request identity layer, which is what the identity track adds.

**Why it matters.** It replaces the perimeter model, in which everything inside the firewall trusted
everything else - the model that lets one compromised laptop reach every server.

## zones and conduits (IEC 62443)

**What it is.** The segmentation model of IEC 62443, the security standard family for industrial
automation. Assets with the same security requirements are grouped into a zone; every path of
communication between zones is a conduit, which is named, minimal and protected by its own controls.
Anything that is not a declared conduit is not allowed to exist.

**Here.** The tailnet tags are the zones and the ACL rules the conduits. SMB between vm100, the
Proxmox host and vm102 is the one data path that runs outside that model, over the LAN, as the
[SMB binding decision](../homelab-server-architecture/docs/decisions/smb-bind-and-lan-access.md) records.

**Why it matters.** It moves the question from "is this port filtered" to "is this path declared".
OT practice adds one priority that IT tends to rank lower: a conduit on which the process depends
should not depend on a service outside the site, which is the argument against putting the storage
path on a tunnel whose control plane is someone else's.
