# Ansible Serial Execution

## The default: parallel

By default, Ansible runs each task on all matching hosts before moving to the next task.
With 7 LXCs, all 7 would download packages at the same time.

## Why parallel can be dangerous

On a Proxmox host with thin-pool storage, parallel apt upgrades caused a real incident:
- All 7 nodes downloaded packages simultaneously
- ~48 MB per node x 7 = ~336 MB written to the pool at once
- Pool hit 100% capacity mid-download
- Result: corrupt binaries, VM freeze, platform-wide outage

## serial: N - how it works

`serial` sets how many hosts run the entire play at once before moving to the next batch.

```yaml
- name: upgrade apt
  hosts: lxcs
  serial: 1     # one host completes all tasks, then the next starts
  tasks:
    - ...
```

With `serial: 1` and 7 hosts: host 1 finishes completely -> host 2 starts -> etc.

## serial values

```yaml
serial: 1       # one at a time (safest, slowest)
serial: 2       # two at a time
serial: "30%"   # 30% of matching hosts at a time
```

## When to use serial

| Situation | Recommendation |
|---|---|
| apt upgrade on shared thin-pool storage | `serial: 1` |
| Rolling restart of a service cluster | `serial: 1` or `serial: "30%"` |
| Independent tasks with no shared resources | no serial needed |
| Time-sensitive fleet-wide change | consider tradeoff |

## Related

- [Playbook Structure](playbook-structure.md)
