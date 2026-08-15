# Proxmox: Thin-Pool Full Recovery

## Symptoms

- `lvs -o lv_name,data_percent` shows `data` at `100.00`
- `qm status <vmid>` returns `status: io-error`
- `df -h /` inside containers looks fine (this is misleading - see below)
- apt upgrades fail with `No space left on device`
- Ansible: `Failed to create temporary directory` on affected nodes

## Why df lies

`df` inside an LXC reports virtual disk usage, not thin-pool utilization.
A container can show 4 GB free while the pool backing it is 100% full.

Always check the pool on the Proxmox host:

```bash
lvs -o lv_name,lv_size,data_percent
```

## Recovery steps

### 1. Free space

```bash
# Clear apt cache on all reachable LXCs
ansible lxcs -m command -a "apt-get clean"

# fstrim via nsenter for all LXCs (must run from Proxmox host)
for ctid in 200 210 211 220 230 240 260; do
  PID=$(lxc-info -n "$ctid" 2>/dev/null | awk '/^PID:/{print $2}')
  nsenter -t "$PID" --mount -- fstrim -v /
done

# fstrim on VMs (run from inside via SSH)
ssh gpu@<vm100-ip> 'sudo fstrim -v /'
ssh storage@<vm102-ip> 'sudo fstrim -v /'
```

### 2. Resume frozen VMs

```bash
qm resume 102
qm status 102   # should return: running
```

### 3. Repair dpkg state on affected nodes

```bash
pct exec 200 -- dpkg --audit
pct exec 200 -- dpkg --configure -a
pct exec 200 -- apt --fix-broken install -y
```

### 4. Reinstall corrupt binaries

```bash
pct exec 230 -- apt-get install --reinstall tailscale
pct exec 260 -- apt-get install --reinstall bash
```

### 5. Check pool status

```bash
lvs -o lv_name,data_percent | grep data
```

Aim for at least 85% before re-running any upgrades.

## Prevention

- Run `snippets/scripts/lxc-fstrim.sh` after every apt upgrade playbook
- Use `serial: 1` in upgrade playbooks
- Add a Prometheus alert for pool utilization above 85%

## Related

- [Linux: LVM Thin Provisioning](../linux/lvm-thin-provisioning.md)
- [Linux: Namespaces & nsenter](../linux/namespaces-nsenter.md)
- [Linux: ELF Binary Corruption](../linux/elf-binary-corruption.md)
