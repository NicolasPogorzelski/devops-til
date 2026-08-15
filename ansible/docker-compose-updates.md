# Updating Docker Compose Stacks with Ansible

How to pull new images and recreate Compose stacks fleet-wide, idempotently,
using `community.docker.docker_compose_v2`.

## Why a module, not `shell`

`shell`/`command` *could* run `docker compose pull && docker compose up -d` - it
is not "too short" for the job. The real reason to use the dedicated module is
**idempotency and structured results**:

- `shell` always reports `changed` (Ansible only sees "command ran, exit 0"); to
  get honest change reporting you would have to hand-build `changed_when`.
- `docker_compose_v2` compares the stack's desired vs actual state itself and
  reports `changed` only when a container was actually (re)created.
- The module returns *which* containers changed; `shell` gives an unparsed
  stdout blob.

This is the same `changed=0`-on-second-run signal targeted by every other role
(node_exporter, chrony).

## The two parameters that matter for *updating*

The module delegates image-pull behaviour to Docker Compose, so a parameter's
default is not automatically what you want for an update.

### `pull` - does it fetch a newer image?

Choices: `always`, `missing`, `never`, `policy` (default).

- `always` - always query the registry and fetch if newer
- `missing` - pull only if the image is absent locally
- `never` - never pull
- `policy` - **no decision of its own**: use each service's `pull_policy` from the
  compose file, and if none is set, Compose's own default - which is effectively
  `missing`.

`policy` is the only value that pushes you out of the Ansible docs (it means "ask
elsewhere"). The Ansible page lists the choices bare with no descriptions; the
definition of `pull_policy` lives in the Docker Compose spec:
<https://docs.docker.com/reference/compose-file/services/#pull_policy>

**Consequence:** the default `policy` ~ `missing` -> will NOT pull a newer build
of a tag that already exists locally -> **useless for updating**. For an update
workflow use `pull: always`.

### `recreate` - does it restart the container?

Choices: `always`, `auto` (default), `never`.

- `auto` - recreate a container only if its **config or image changed**.

This is exactly right for updates and you don't even need to write it (it's the
default). It is what gives you idempotency: if `pull` fetched a new image, `auto`
sees the image changed -> recreates; if nothing changed -> no recreate -> `changed=0`.

### The key insight: pull and recreate are *separate*

`pull: always` means "always *look*", not "always *change*". If the registry has
nothing new, the local image is byte-identical, `recreate: auto` sees no change,
and the run is `changed=0`. One parameter queries the registry, the other decides
the container restart. Idempotency survives `pull: always`.

## Where the compose paths come from

Ansible cannot read your Markdown node docs at runtime - it needs the path as a
**variable**. A path that differs per node belongs in `host_vars/<node>.yml`.
A node usually has *several* stacks, so model it as a **list**:

```yaml
# inventory/host_vars/vm100.yml
compose_projects:
  - /opt/docker/jellyfin
  - /opt/docker/audiobookshelf
  - /opt/docker/ollama
```

The task never hard-codes a path - it references the variable *name* and iterates
with `loop`; the current element is `item` (same pattern as the `breakglass` role's
`loop` over `breakglass_pubkeys`):

```yaml
- name: Update Docker compose stacks
  community.docker.docker_compose_v2:
    project_src: "{{ item }}"
    pull: always
    state: present
  loop: "{{ compose_projects }}"
```

**Why one task works on every host unchanged:** `compose_projects` is resolved
*per host*. On vm100 Ansible reads `host_vars/vm100.yml`; on lxc211 it reads
`host_vars/lxc211.yml`. Same variable name, host-bound value. Data lives in the
inventory, logic lives in the task - the node docs stay the human source of
truth, the host_var is its machine-readable mirror.

`loop` in Ansible is **sequential by default** - stacks on one host update one
after another with no extra config. Parallelism would be the special case.

## Scoping the play: only Docker nodes

Not every node runs Docker. Native-stack nodes (e.g. Nextcloud on Apache/PHP,
PostgreSQL as a systemd service) have no compose dir. Verify which nodes actually
run Compose rather than assuming:

```bash
ansible all -m shell -a 'docker compose ls 2>/dev/null || echo NO-DOCKER'
```

Two clean ways to keep the play off non-Docker nodes - they solve **different
problems** and are combined in real setups:

| | Group targeting | Safe no-op default |
|---|---|---|
| Answers | *Who* do I touch? (intent) | What if a var is missing? (robustness) |
| Guards against | touching the wrong nodes | crash on undefined variable |
| Lives in | `hosts.yml` (a `docker` group) | role `defaults/main.yml` (`compose_projects: []`) |

- **Group** (`hosts: docker`): explicit membership, readable in the inventory; a
  forgotten new node is *visible* (not in the group) rather than silently skipped.
- **Safe default** (`compose_projects: []`): an empty `loop` is 0 iterations ->
  harmlessly skipped. Without a default, referencing an undefined `compose_projects`
  is a **fatal error** that kills the play on that host. The empty list turns the
  crash into a no-op. This is the same pattern as `breakglass_pubkeys: []` in
  `roles/breakglass/defaults/main.yml`.

The professional norm: a reusable role ships safe no-op defaults in
`defaults/main.yml` (lowest precedence, can't crash on a missing var), and the
*playbook* picks *where* it runs via `hosts:`. Default = "can't break", group =
"runs in the right place".

## Implementation notes (verified on the homelab)

Built and run against 6 nodes (2026-06-11). What the design doc above could not
predict until it actually ran:

- **`become: true` is mandatory.** The discovery command above
  (`docker compose ls 2>/dev/null || echo NO-DOCKER`) reported `NO-DOCKER` on
  *every* node - including ones known to run Compose. The `2>/dev/null` masked the
  real error: the `ansible` user is not in the host `docker` group, so it cannot
  read `/var/run/docker.sock`. Re-running with `-b` (sudo) and without swallowing
  stderr surfaced the truth. **Lesson:** when a sweep reports the same negative on
  hosts you *know* are positive, suspect a masked permission error - drop the
  `2>/dev/null`, add `-b`. The playbook needs `become: true` for the same reason.

- **Idempotency proof needs two real runs, not `--check`.** `docker_compose_v2`
  in check mode cannot inspect or pull, so it conservatively reports `changed` for
  *every* stack - a false positive, same limitation class as an apt
  install->service dependency in check mode. The meaningful test is: run for real
  (run 1 = `changed`, pulls + first-run convergence), then run again - run 2 must
  be `changed=0`. That second run is what proves `pull: always` is "always look",
  not "always change".

- **`docker --format` collides with Jinja2 via `ansible -a`.** A health check with
  `docker ps --format '{{.Names}}'` returns nothing: Ansible runs the `-a` string
  through Jinja2 first, and `{{ }}` is *also* Jinja syntax, so Jinja tries to
  resolve `.Names` and yields empty. Avoid `--format '{{...}}'` in
  ad-hoc `-a`; use `--filter` / `--format table` or query a different way.

- **Project name vs dir basename.** `project_src` derives the Compose project name
  from the directory basename *unless* the compose file pins a top-level `name:`.
  A stack living in `/opt/vaultwarden/compose` would become project `compose`
  without the pinned `name: vaultwarden` - the module honours the pin because it
  shells out to `docker compose`.

## The sync gap: a role that updated nothing (2026-07-08)

The role above worked for a month and was still silently broken. It ran
`docker_compose_v2` against whatever `docker-compose.yml` was **already on the
node** - it never pushed `docker/<service>/docker-compose.yml` from the repo. So
pinning an image tag in the repo (e.g. paperless `:latest` -> a fixed version,
committed 2026-06-17) changed nothing live: the node's own compose file still
said `:latest`, and `pull: always` faithfully pulled *latest*. paperless-ngx and
tika ran the rolling tag for three weeks despite the repo showing them pinned.

The trap is that every symptom pointed the wrong way:

- The repo *looked* correct - the pin was right there in Git.
- The role *looked* correct - `pull: always` + `recreate: auto`, idempotent,
  `changed=0` on the second run. It was faithfully converging the node to the
  node's own stale file.
- The generic learning above ("data lives in the inventory, logic lives in the
  task") quietly assumed the on-node file *was* the repo file. Nothing enforced
  that.

**Root cause, stated generally:** a config-management role must own the delivery
of its **source of truth**, not just act on remote state. "Idempotent against the
node" is not "converged to the repo" when the repo artifact is never shipped.
The audit question that catches this: *does the role read anything from the repo
tree, or does every task operate on files that must already exist on the target?*
If it's the latter, the repo is documentation, not control.

### The fix

Add a `copy` task that ships the repo compose file to the node **before**
recreate:

```yaml
- name: Sync compose file from repo to node
  ansible.builtin.copy:
    src: "{{ role_path }}/../../../docker/{{ item.src }}/docker-compose.yml"
    dest: "{{ item.dest }}/docker-compose.yml"
    owner: root
    group: root
    mode: '0644'
  loop: "{{ compose_projects }}"
  loop_control:
    label: "{{ item.dest }}"
```

- `src` uses `{{ role_path }}/../../../docker/...` - `role_path` is the role's own
  directory; three `../` climb back to the repo root, so the source resolves
  regardless of where `ansible-playbook` is invoked from. (`copy` also searches a
  role's `files/`, but here the source of truth is the shared `docker/` tree, not
  a role-local copy - duplicating it into `files/` would reintroduce a drift
  surface.)
- The `recreate` task must run *after* this, so `recreate: auto` sees the newly
  written file, detects the image change, and restarts.

### Why `compose_projects` had to change shape

A flat path list (`- /opt/paperless`) only encodes the **node** path. To also
copy *from* the repo, each entry needs the **repo** subdir too - and the two
basenames don't always match:

```yaml
compose_projects:
  - { dest: /opt/paperless, src: paperless }
  - { dest: /srv/calibreweb, src: calibre-web }        # basenames differ
  - { dest: /opt/vaultwarden/compose, src: vaultwarden }
```

`dest` = `project_src` on the node (what the old list held); `src` = subdir under
repo `docker/`. `item` becomes a dict, so every reference is now `item.dest` /
`item.src` instead of bare `item`. The lesson generalises: the moment a loop
element needs a second, independent attribute, promote it from a scalar to a
`{k: v}` dict - don't try to derive one path from the other with string surgery
when they're genuinely unrelated names.

**Verify before trusting:** dry-run with `--check --diff` first - the `copy`
diffs show exactly which nodes had a stale compose file. Then confirm the live
tag afterwards (`docker inspect <container> | grep Image`, not `--format` - see
the Jinja2 collision above).

## Related

- [Inventory Groups](inventory-groups.md) - host_vars/group_vars, variable precedence
- [Roles](roles.md) - `defaults/main.yml`, safe defaults
- [Task Control](task-control.md) - `shell` vs `command`, `changed_when`
- [Serial Execution](serial-execution.md) - `serial: 1` rationale
