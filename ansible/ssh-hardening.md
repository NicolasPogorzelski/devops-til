# SSH Hardening with Ansible

## What we harden

Two directives in `/etc/ssh/sshd_config`:

- `PasswordAuthentication no` — disables password-based SSH login; forces key-based auth only. Eliminates brute-force attack vector.
- `PermitRootLogin no` — disables direct SSH login as root. Use a sudo-enabled user instead. Root actions are auditable via sudo logs; direct root SSH is not.

Default values (Debian 12):
- `PasswordAuthentication yes` (often commented out as `#PasswordAuthentication yes`)
- `PermitRootLogin prohibit-password` (allows root with key, but not password)

## Module: ansible.builtin.lineinfile

Used to set or replace a single line in a file. Does not require deploying a full template.

```yaml
- name: disable password authentication
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: ^#?PasswordAuthentication
    line: PasswordAuthentication no
  notify: reload sshd
```

Key parameters:
- `path` — the file to modify
- `regexp` — regex to find the target line; the matched line is replaced by `line`
- `line` — the desired final content of the line
- `notify` — triggers the named handler only if this task made a change

## regexp pattern workflow

1. Look at the actual line in the file: `grep "PasswordAuthentication" /etc/ssh/sshd_config`
2. Identify all variants (commented, uncommented, different values)
3. Build pattern left to right:
   - `^` — anchor to line start (prevents matching mid-line occurrences)
   - `#?` — optional `#` (matches both commented and uncommented lines)
   - rest — the fixed keyword

Reference: `man 7 regex`, or test patterns at regex101.com.

## Handler

```yaml
- name: reload sshd
  ansible.builtin.systemd_service:
    name: ssh
    state: reloaded
```

- `state: reloaded` — sends SIGHUP to sshd, reloads config without dropping existing sessions
- `state: restarted` — full restart, drops all active SSH connections (avoid on remote hosts)
- Under Debian 12 the service is named `ssh`, not `sshd`

## Dry-run workflow (standard from here on)

Always run with `--check --diff` before applying:

```bash
ansible-playbook playbooks/ssh-hardening.yml --check --diff
```

- `--check` — simulate the run, make no changes
- `--diff` — show before/after for file modifications (like git diff)

Only apply after reviewing the diff output.

## Idempotency signal

- First run: `ok=4` (Facts + 2 tasks + handler)
- Second run: `ok=3` (Facts + 2 tasks, handler not triggered because no task was `changed`)

`notify` only fires when the task reports `changed`. On a second run with no changes, the handler is skipped — this is expected and correct.

## The drop-in that wins: sshd_config.d ordering (2026-07-08)

Editing `PasswordAuthentication no` into `/etc/ssh/sshd_config` (the `lineinfile`
task above) is **not enough** on a host that also has a `sshd_config.d/` drop-in
setting it back. On one node the role reported `changed=0` — looked hardened —
while the host still accepted password logins.

Two sshd facts explain it:

1. **sshd applies the *first* match for a directive**, not the last. Once
   `PasswordAuthentication yes` is seen, every later occurrence is ignored.
2. **`Include /etc/ssh/sshd_config.d/*.conf` sits near the *top*** of the main
   `sshd_config` on Debian/Ubuntu, and expands its files in **filename-sort
   order**. So `sshd_config.d/50-cloud-init.conf` (written by cloud-init with
   `PasswordAuthentication yes`) is parsed *before* the line the role edited lower
   in the main file — and wins.

Only the cloud-init'd node was affected (it's a VM; the LXCs have no such
drop-in). The `changed=0` was true and misleading at once: the line the role
manages *was* already `no`; it just wasn't the line sshd obeys.

### Root-cause discipline: verify effective config, not the file you wrote

The line you edited is not the effective config. `sshd -T` prints the fully
resolved configuration after all Includes and first-match resolution — that is
ground truth:

```bash
sshd -T | grep -i passwordauthentication      # -T: dump effective config, then exit
```

If that says `yes` while your file says `no`, an earlier-sorted drop-in is
overriding you. This is the verification step that turns "I set it" into "it is
set".

### The fix: sort a drop-in *before* the offender, don't edit the offender

```yaml
- name: Deploy sshd_config.d drop-in that wins over distro-provided defaults
  ansible.builtin.copy:
    dest: /etc/ssh/sshd_config.d/00-hardening.conf
    owner: root
    group: root
    mode: '0644'
    content: |
      PasswordAuthentication no
      PermitRootLogin no
  notify: reload sshd
```

- `00-` sorts before `50-cloud-init.conf`, so with first-match-wins **it wins**.
- We do **not** edit or delete `50-cloud-init.conf`: cloud-init owns it and can
  regenerate it on a future boot, silently undoing an in-place edit. Adding an
  earlier-winning file is durable against that; editing the owned file is not.
- Same `notify: reload sshd` handler — the drop-in only takes effect after sshd
  re-reads its config.

Generalised lesson: when a value is assembled from an ordered set of fragments
(sshd Includes, `conf.d/` dirs, systemd drop-ins, `sysctl.d/`), **change the
resolution order in your favour instead of fighting the fragment you don't own** —
and always verify the *resolved* value, not the fragment you wrote.

### Verifying the applied change: a reused socket proves nothing (2026-07-09)

After applying the drop-in, the obvious check is "can I still get in?". If your SSH client has
connection multiplexing enabled (`ControlMaster`/`ControlPath` — Ansible's `ansible.cfg` turns it
on by default), a new `ssh host …` may travel over the **existing** socket and never
re-authenticate. The test passes whether or not the change is sane.

```bash
ssh -o ControlMaster=no -o ControlPath=none user@host 'sudo sshd -T | grep -i passwordauth'
```

Both options force a genuinely new connection, and therefore a real authentication.

Three more habits that make an sshd change safe to apply remotely:

- The handler must `reload`, not `restart`: existing sessions survive while you verify.
- Check what you are about to remove. `PermitRootLogin no` is a no-op if `/root/.ssh/authorized_keys`
  is empty — but if break-glass runs as root, it is a lockout. `wc -l < /root/.ssh/authorized_keys`
  before, not after.
- Know the out-of-band path before you need it: `pct exec <ctid> -- bash` for LXCs, the hypervisor
  console for VMs. SSH cannot rescue a broken sshd.
