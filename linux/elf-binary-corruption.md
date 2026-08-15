# ELF Binaries & Corruption

## What ELF is

ELF (Executable and Linkable Format) is the standard binary format on Linux. Every
executable (`/bin/bash`, `/usr/sbin/tailscaled`) and shared library is an ELF file.

The file starts with a magic number (`\x7fELF`) that identifies it as a valid ELF binary.
If a binary is partially written (e.g. download interrupted mid-write), the magic number
or structure is missing - the kernel refuses to execute it.

## How to detect a corrupt binary

```bash
file /usr/sbin/tailscaled
```

**Healthy output:**
```
/usr/sbin/tailscaled: ELF 64-bit LSB executable, x86-64, ...
```

**Corrupt output:**
```
/usr/sbin/tailscaled: data
```

`data` means the file has no recognizable format - it was written incompletely.

## How corruption happens

When the LVM thin-pool is full, disk writes fail at the block level. If apt is downloading
and writing a package at that moment, the write is truncated mid-file. The resulting binary
on disk is a partial file with no valid ELF header.

Common victims during interrupted apt upgrades:
- `tailscale` (~40 MB binary, large download window)
- `bash` (frequently updated with security patches)
- `login`, `libpam-modules` (upgraded together as a set)

## Symptoms

| Symptom | Cause |
|---|---|
| SSH connects but `echo test` returns `Exec format error` | `bash` binary corrupt - shell cannot start |
| `systemctl status tailscaled` shows `status=203/EXEC` | tailscaled binary corrupt |
| `dpkg-deb: error: not a Debian format archive` | `.deb` file corrupt in apt cache |

## Fix - reinstall the package

```bash
apt-get install --reinstall <package>
```

This re-downloads the package and overwrites the corrupt binary. No config files are changed.

```bash
# Examples
apt-get install --reinstall tailscale
apt-get install --reinstall bash
```

## Fix - corrupt .deb in apt cache

If the `.deb` file itself is corrupt (partial download), apt will refuse to install it.
Clear the cache so apt re-downloads:

```bash
apt-get clean
apt-get dist-upgrade
```

## Related

- [LVM Thin Provisioning](lvm-thin-provisioning.md)
