# Ansible Privilege Escalation

## The problem

Ansible connects as a specific user (e.g. `gpu`, `storage`). Some tasks require root
(apt, systemctl, writing to `/etc/`). `become` handles the escalation.

## Key fields

| Field | Purpose | Default |
|---|---|---|
| `become: true` | Enable privilege escalation | false |
| `become_user: root` | User to escalate to | root |
| `become_method: sudo` | Escalation method | sudo |

`become: true` alone is enough in most cases — root is the default target.

## Placement — play level vs task level

**Play level** — applies to all tasks in the play:

```yaml
- name: upgrade apt
  hosts: vms
  become: true
  tasks:
    - name: update cache
      ansible.builtin.apt:
        update_cache: yes
    - name: upgrade
      ansible.builtin.apt:
        upgrade: dist
```

**Task level** — applies only to that specific task:

```yaml
tasks:
  - name: write config as root
    ansible.builtin.copy:
      dest: /etc/myapp.conf
      content: "setting=value"
    become: true
```

Use play level when all tasks need root. Use task level when only specific tasks need it.

## How Ansible uses sudo

When `become: true` is set, Ansible escalates the **entire Python module execution** to root
via sudo — not just the final command. This means the sudo rule must allow the Python
interpreter, not just the tool being used.

This is why `NOPASSWD: /usr/bin/apt-get` is not enough for Ansible — the actual sudo call
is to Python, not apt-get.

For Ansible-managed nodes, use:

```
<user> ALL=(root) NOPASSWD: ALL
```

## Configuring NOPASSWD sudo

Create a file in `/etc/sudoers.d/` (never edit `/etc/sudoers` directly):

```bash
echo 'gpu ALL=(root) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/ansible-apt
chmod 440 /etc/sudoers.d/ansible-apt
```

**Important:** The file must be owned by root. sudo refuses files with wrong ownership:

```
sudo: /etc/sudoers.d/ansible-apt is owned by uid 1000, should be 0
```

Verify with:

```bash
sudo -n id   # should return uid=0(root) without password prompt
```

## The dedicated ansible user pattern

For production, create a dedicated `ansible` service account instead of reusing
application users (`gpu`, `storage`). This account has:
- SSH key-based auth only
- `NOPASSWD: ALL` sudo
- No other purpose

This avoids per-user sudo rules and makes inventory configuration consistent across all nodes.

## Related

- [Playbook Structure](playbook-structure.md)
