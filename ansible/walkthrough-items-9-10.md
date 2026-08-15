# Roadmap #9 & #10: Fleet Docker Updates and Declarative Postgres Provisioning

Two automation tasks built back to back. They look unrelated - one restarts
containers, the other creates databases - but they are the same role twice, and
seeing the shared skeleton is more useful than either task on its own.

## The skeleton every role here shares

An Ansible setup splits into four parts, and the discipline is keeping them
separate. Each answers exactly one question:

| Part | File | Answers |
|---|---|---|
| Inventory group | `inventory/hosts.yml` | *Which* hosts? |
| `host_vars` | `inventory/host_vars/<node>.yml` | What is true of *this one* host? |
| Role | `roles/<name>/` | The reusable *logic*. |
| Playbook | `playbooks/<name>.yml` | Run *this role* on *that group*. |

The rule that makes it scale: **data lives in the inventory, logic lives in the
role.** A good role never names a path, an IP, or a hostname. It references a
variable, and the inventory fills that variable in differently for each host.
That is why a single ten-line role drives six machines that all have different
stack layouts.

Two more ideas carry the whole thing:

**Idempotency is the acceptance test, not a nice-to-have.** A run that converges
the fleet to a desired state must do nothing the second time. So the proof a role
is finished is a second run reporting `changed=0`. If the second run still shows
changes, the role isn't declaring state - it's blindly *doing*, every time, which
is the bug you catch before merging.

**The safe default belongs to the role.** Every role ships
`defaults/main.yml`, which sits at the bottom of Ansible's variable precedence -
anything overrides it. That makes it the right place for a neutral fallback like
`compose_projects: []` or `postgres_tenants: []`. A host that never sets the
variable still runs cleanly: the loop iterates over an empty list and the role
no-ops, instead of aborting on an undefined variable. It goes in the role's
`defaults/`, not in `group_vars/all`, because the default is a property of the
*role* (it ships with it, keeps it self-contained), while a group var is a fact
about *this particular inventory*.

---

## #9 - Updating Compose stacks across the fleet

Six nodes run services as Docker Compose stacks. Updating them by hand is the
same four keystrokes on each box: SSH in, `cd`, `docker compose pull`, `up -d`.
The goal was one playbook that does it everywhere, one node at a time.

### Don't assume which nodes run Docker - and watch the lie

The first sweep was meant to list every node's Compose projects:

```bash
ansible all -m shell -a 'docker compose ls 2>/dev/null || echo NO-DOCKER'
```

Every node answered `NO-DOCKER`, including the ones plainly running containers.
That result is too clean to be true, which is the tell that the *test* is broken,
not the fleet. The `2>/dev/null` had swallowed the real error.

Re-running with errors visible and with privilege escalation gave the truth:

```bash
ansible all -b -m shell -a 'docker compose ls 2>&1 || echo "FAILED-rc=$?"'
```

`-b` runs the command through `sudo`; `2>&1` folds stderr back into the output
instead of discarding it. Now the honest split appeared: the real Docker nodes
listed their stacks, and the genuinely Docker-free nodes returned
`docker: not found` with exit code 127. The earlier blanket failure was a
permission problem - the `ansible` user isn't in the host `docker` group, so
without root it can't reach `/var/run/docker.sock`. The fix isn't a workaround;
it's a design constraint discovered: **the playbook has to run with `become: true`,**
proven rather than assumed.

The honest output also handed over the ground truth for free - the real stack
directories, straight from Compose's own `CONFIG FILES` column, with no guessing
from documentation that might have drifted.

### The four pieces

The `docker` group lists the six Compose nodes. Membership is cheap - a host can
sit in many groups and its variables merge - so `docker` coexists with the
existing `lxcs`/`vms` grouping.

The per-host stack directories go in `host_vars`, as a list, because some nodes
run more than one stack:

```yaml
# host_vars/vm100.yml - this node runs two stacks
compose_projects:
  - /opt/docker/audiobookshelf
  - /opt/docker/jellyfin
```

The role is a single task:

```yaml
- name: Pull latest images and recreate changed Compose stacks
  community.docker.docker_compose_v2:
    project_src: "{{ item }}"
    state: present
    pull: always
  loop: "{{ compose_projects }}"
  loop_control:
    label: "{{ item }}"
```

The choice of `docker_compose_v2` over `shell: docker compose pull && up -d` is
about honesty, not brevity. A `shell` command always reports `changed`, because
all Ansible can observe is "a process ran and exited 0". The module inspects the
stack and reports `changed` only when a container is actually recreated - which
is what makes the `changed=0` idempotency signal meaningful. `loop` walks the
stack list, sequentially by default, so stacks on one host update one after
another with no extra configuration.

The non-obvious parameter is `pull`. It and `recreate` are *independent*
decisions, and conflating them is the usual mistake:

- `pull: always` means "always *check* the registry for a newer image". The
  default, `policy`, defers to Compose's own pull policy, which boils down to
  "only pull if the image is missing locally" - fine for first install, useless
  for updating a tag that already exists. Updating requires `pull: always`.
- `recreate: auto` (the default) recreates a container only when its image or
  config changed.

Together they give updates that stay idempotent: every run looks, but only a run
where the registry actually moved produces a restart. "Always look" is not
"always change", and that distinction is the entire reason a daily update
playbook can be safe to run on a schedule.

The playbook is glue, and the two non-default settings both earned their place:

```yaml
- hosts: docker
  serial: 1        # one node fully done before the next
  become: true     # the docker.sock permission lesson
  roles:
    - docker-compose-update
```

`serial: 1` matters on a single-host hypervisor. Pulling and recreating all six
stacks at once is a resource spike, and a bad upstream image would hit the whole
fleet simultaneously. One node at a time keeps the blast radius at one node.

### Verifying cheaply before verifying expensively

The checks ran from free to costly: `--syntax-check`, then
`ansible-inventory --graph docker` to confirm the six members, then a
`debug var=compose_projects` to confirm the host_vars resolve (vm100 showing both
stacks). The `--check` dry run came with a caveat worth remembering:
`docker_compose_v2` in check mode can't inspect or pull, so it reports `changed`
for every stack - a false positive. What the dry run genuinely proves is
connectivity and `become` across all six; the change count is noise. The real
proof was the pair of live runs: the first changed all six and failed none, the
second reported `changed=0` everywhere. Health afterward: zero unhealthy
containers, none restarting or exited.

### Docker's `--format` syntax collides with Jinja2

A first attempt at a health readout returned nothing:

```bash
ansible docker -b -m shell -a 'docker ps --format "{{.Names}}"'
```

`docker ps --format` has its own templating syntax, and its placeholders are
written `{{ }}` - the exact markers Jinja2 uses. Ansible runs the `-a` string
through Jinja2 *before* the remote host ever sees it, so Jinja2 grabbed
`{{.Names}}`, tried to resolve `.Names` itself, found nothing, and forwarded an
empty format string. The lesson is mechanical: when a command's own syntax uses
`{{ }}`, it fights Ansible's templating. Reach for `--filter`, or `--format
table`, or restructure the query - here `--filter` did the job.

---

## #10 - Declarative Postgres provisioning

LXC260 is the single Postgres host for the platform; every service that needs a
database gets one there. Onboarding a new service today is a manual `psql`
checklist. The aim is to make it declarative: list a tenant in a variable, run
the playbook, and the database, role, grants, and host-based firewall rule exist.

### Why the role has to understand four layers

Access to this database is gated in layers, and the role can't ignore any of
them:

1. **Tailscale ACL** - only certain tags can reach port 5432 at all. Lives in the
   Tailscale control plane; out of scope for Ansible.
2. **`listen_addresses`** - Postgres binds its Tailscale IP only, never the LAN.
3. **`pg_hba.conf`** - a per-client allowlist. One line per consumer:
   `hostssl <db> <user> <client-ip>/32 scram-sha-256` - this user, this database,
   only from this exact address, only over TLS, only with SCRAM. It is the
   firewall *inside* the database, and a new tenant is invisible until its line
   exists.
4. **Grants** - what the role may do once connected.

So provisioning a tenant is not just `CREATE DATABASE`. The full manual sequence
the role replaces is:

```sql
CREATE DATABASE <svc>_db;
CREATE USER <svc>_user WITH PASSWORD '<password>';
GRANT ALL PRIVILEGES ON DATABASE <svc>_db TO <svc>_user;
\c <svc>_db
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO <svc>_user;
```

plus the `pg_hba.conf` line and a `systemctl reload postgresql`.

### How the role connects: peer auth, no password

Verified on the node: `psql` works as the `postgres` OS user with no password,
because of the `local all postgres ... peer` line in `pg_hba.conf`. Peer auth
trusts the operating-system identity - if you are the Linux `postgres` user on
the local socket, Postgres lets you in as the superuser. So the role runs on
LXC260 as `become_user: postgres` over the local socket, the same mechanism the
backup job already uses. There is no admin password to manage or leak.

### The decisions

**Full scope.** The role does database, user, grants, the `pg_hba.conf` line, and
the reload - the entire checklist. Stopping at "database and user" was rejected
because it leaves the firewall edit manual, which is half the toil and the half
most likely to be forgotten.

**Test tenant first.** Build and prove the mechanics against a throwaway
`test_db`/`test_user`, with the live OpenWebUI and Paperless databases untouched,
before considering adopting the real tenants. The reason is specific to this
module set: `postgresql_user` re-asserts the password on every run. Declare a
live tenant with a password that doesn't match what the service actually uses,
and the next run silently rotates it and breaks that service's login. A throwaway
tenant cannot break anything, so the dangerous path gets exercised where it's
free.

**List-shaped data.** One tenant is one entry in a `postgres_tenants` list
(`name`, `user`, `consumer_cidr`, a Vault-referenced password); the role loops.
It lives in `host_vars/lxc260.yml` because LXC260 is the only database host, with
`postgres_tenants: []` as the role's safe default.

### Secrets, end to end without printing one

Database passwords can't sit in plaintext in a repo that's public and permanent.
Ansible Vault encrypts individual values with AES-256; the key lives in a
git-ignored, mode-600 `~/.vault_pass` on the control node and loads automatically
from `ansible.cfg`. For the test tenant:

```bash
PW=$(openssl rand -base64 24)
ansible-vault encrypt_string "$PW" --name 'vault_test_dbpass' \
  >> inventory/group_vars/all/vault.yml
```

`openssl rand -base64 24` is 24 random bytes - 192 bits - as a 32-character
string. `encrypt_string` emits a ready-to-paste `vault_test_dbpass: !vault |`
block, appended to the vault file. The round trip was confirmed without ever
echoing the secret:

```bash
ansible lxc260 -m debug -a "msg={{ vault_test_dbpass | length }}"   # -> 32
```

The host_var references it as `"{{ vault_test_dbpass }}"`; the plaintext exists
only in memory during the run.

One sanitisation detail shapes the design: the committed repo forbids bare
Tailscale IPs, so the test tenant's `pg_hba` source is `127.0.0.1/32` - valid,
harmless, not a secret. Real tenants avoid hard-coding an IP entirely by deriving
it from the inventory, e.g.
`consumer_cidr: "{{ hostvars['lxc230'].ansible_host }}/32"`, which keeps literal
Tailscale addresses out of every committed file.

### Each manual step becomes one module

Using the `community.postgresql` collection, the checklist maps cleanly, every
task looping over `postgres_tenants`:

| Manual step | Module |
|---|---|
| `CREATE DATABASE` | `postgresql_db` |
| `CREATE USER ... PASSWORD` | `postgresql_user` |
| `GRANT ... ON DATABASE` | `postgresql_privs` (type `database`) |
| `REVOKE`/`GRANT ON SCHEMA public` | `postgresql_privs` (type `schema`) |
| `pg_hba.conf` line | `postgresql_pg_hba` |
| `systemctl reload postgresql` | handler, notified on a pg_hba change |

The database tasks run as `become_user: postgres` over peer auth; the reload
handler runs as root, since systemd needs it. The pg_hba path is pinned from a
verified fact rather than a guess - the node runs PostgreSQL 15.16, so
`/etc/postgresql/15/main/pg_hba.conf`.

### What the build surfaced

The role works - real run `failed=0`, rerun `changed=0`, and the test database,
role, and `pg_hba` line all verified present before teardown. The interesting part
was two bugs the dry run caught, both worth carrying forward:

- **Becoming an unprivileged user needs `acl`.** `become: true` then
  `become_user: postgres` made Ansible fail to hand its temp files to postgres
  (`chmod: invalid mode 'A+user:postgres:rx:allow'`). Root cause, verified:
  `setfacl` was missing, so Ansible's POSIX-ACL handoff fell back to a method that
  doesn't work on Linux. Fix: install `acl` as a prerequisite task before the
  `become_user` block. This recurs with any role that becomes a service account.
- **Don't put a secret in the loop variable.** The first cut carried the password
  inside each tenant dict, with `no_log` on only the user task. When an *earlier*
  task failed, Ansible dumped the failed `item` - password in clear. The loop item
  reaches every task; `no_log` on one doesn't protect the rest. Fix: keep only
  non-secret fields in `postgres_tenants` and look the password up from a separate
  dict, read solely by the `no_log` user task - and rotate the burned password.

These are written up in full in
[Provisioning PostgreSQL Tenants](postgresql-provisioning.md). The test tenant was
then torn down (`state: absent` plus reload), and the committed `host_vars` ends at
`postgres_tenants: []` with a commented example, so live tenants get adopted as a
deliberate later step rather than swept in by accident.

## Related

- [Docker Compose Updates](docker-compose-updates.md)
- [Inventory Groups](inventory-groups.md)
- [Roles](roles.md)
- [Privilege Escalation](privilege-escalation.md)
- [Ansible Vault](ansible-vault.md)
- [Serial Execution](serial-execution.md)
