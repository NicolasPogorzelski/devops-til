# Samba Access Control & SMB Client Compatibility

How to scope who can reach a Samba share, why a client that "supports SMB" can still
fail to mount, and the commands to diagnose it. Companion to
[Samba Server Config](samba-server-config.md) (server structure).

---

## Two separate gates: SMB dialect vs signing

```ini
server min protocol = SMB3      # alias for SMB3_11 (= SMB 3.1.1) in modern Samba
server signing      = mandatory # every session must be signed
```

- `server min protocol = SMB3` does **not** mean "any SMB3". In modern Samba it is an alias
  for `SMB3_11` (SMB **3.1.1**). A client offering only SMB 3.0 (`vers=3.0`) is rejected
  (`EOPNOTSUPP`).
- A client must satisfy **both** the minimum dialect **and** mandatory signing. Failing
  either makes the negotiate phase fail — before authentication.

## Diagnosing "the client can't connect"

`Allowed connection` is **not** success. In the per-machine log, `Allowed connection from
<ip>` is written right after the TCP accept + `hosts allow` check, **before** protocol
negotiation completes. If the session then drops with no auth lines, it failed at
**negotiate** (dialect/signing), not at auth.

Tools:

| Command | What it shows |
|---|---|
| `smbstatus -b` | Active sessions: user, client IP, **Protocol Version** (e.g. `SMB3_11`), **Signing** (e.g. `AES-128-CMAC`) |
| `ss -tlnp \| grep ':445'` | Which addresses `smbd` listens on (`0.0.0.0`/`[::]` = all interfaces) |
| `testparm -s` | The **effective** config including defaults |
| `smbcontrol smbd debug 3` / `... debug 0` | Raise/restore log verbosity **at runtime** — no restart, no config edit |

Where the logs are: `log file = /var/log/samba/%m.log`. `%m` is the client NetBIOS name (or
IP). **Connection/auth events go to that per-machine file, not to `journalctl -u smbd`**,
which only shows daemon start/stop. Early failures (before the client name is known) land in
`/var/log/samba/.log` (empty `%m`). The dir is `root:adm 0750`, so expand the glob as root:
`sudo sh -c 'grep -i denied /var/log/samba/*.log'`.

## `hosts allow` / `hosts deny` — default-deny allow-list

```ini
hosts allow = 127.0.0.1 100.64.0.0/10 <trusted-ip> <trusted-ip>
hosts deny  = 0.0.0.0/0
```

- `allow` wins over `deny`, so listed hosts get in and everyone else is denied.
- **Application-layer, not a firewall**: the TCP port stays open; `smbd` accepts the socket
  and then rejects → `Denied connection from <ip>` in the log. The port is still reachable.
- Evaluated **per new connection**. `smbcontrol smbd reload-config` applies it without
  dropping existing sessions (they keep running until they reconnect).
- IPv4 vs IPv6: `0.0.0.0/0` only covers IPv4. `smbd` also listens on `[::]`; add IPv6 ranges
  if you have IPv6 clients.

## Discovery ≠ connection (nmbd vs smbd)

- **nmbd** (UDP 137/138) announces/browses the server → makes it **visible**.
- **smbd** (TCP 445) is the file service → `hosts allow` gates **this**.

A client can still **see** the server (NetBIOS broadcast, or a saved mount entry) while being
**denied** access to the share. "Visible" is not "mountable" — verify by actually mounting,
not by whether it appears in a list.

## "Supports SMB" is not enough: app vs OS mounter

The same device can have two different SMB implementations:

- An **app** can bundle its own SMB client. Example: CX File Explorer ships a modern SMB3
  client and connects to an SMB-3.1.1+signing server fine.
- The **OS / native mounter** may use an older stack. Example: the NVIDIA Shield's built-in
  network-storage mount cannot negotiate SMB 3.1.1 + mandatory signing → it fails while the
  app succeeds against the same server.

Android storage models matter for the **consumer**:

- **SAF / DocumentsProvider** (file managers, CIFS Documents Provider) exposes files as
  `content://` URIs — **not** a real filesystem path. Apps that need a real path (e.g.
  RetroArch loading ROMs) cannot use these.
- A real filesystem path for SMB on Android needs a kernel `mount.cifs` = **root**.

Lesson: check **which component** connects (app vs OS) and whether the consumer needs a real
path or accepts a `content://` URI — before assuming "the device supports SMB" is enough.

## Topology note: same-host VM↔VM traffic

On a single Proxmox host, two VMs on the same bridge (`vmbr0`) communicate **host-internally**
— the frames are switched port-to-port inside the host and do **not** egress the physical
uplink, even though they use LAN-subnet addresses.

Implication: wrapping a host-internal path in Tailscale (WireGuard) adds encryption overhead
for ~no security gain (it never touched an untrusted wire). Keep host-internal storage traffic
on the bridge; reserve Tailscale for traffic that actually crosses an untrusted boundary.
