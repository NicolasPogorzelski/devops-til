# SSH Key Management

## Why key-based auth instead of passwords

- Passwords can be brute-forced; modern SSH keys cannot in any practical timeframe
- A leaked password gives full access; a leaked private key can be revoked at the server
- Automation (Ansible, scripted deploys) cannot prompt for a password — keys are required
- Key fingerprints make audit trails meaningful

## Key types

| Algorithm | Key size | Use it? |
|---|---|---|
| `rsa` 2048 | small | Avoid for new keys — outdated |
| `rsa` 4096 | large, slow | Compatible everywhere, but ed25519 is better |
| `ecdsa` | small | OK; some prefer to avoid due to NIST curve concerns |
| `ed25519` | 256-bit | **Default choice.** Fast, short keys, modern crypto, supported on every current SSH server |

## Generate a key pair

```bash
ssh-keygen -t ed25519 -C "nico@laptop-2026"
```

| Flag | Meaning |
|---|---|
| `-t ed25519` | Algorithm |
| `-C "<comment>"` | Comment appended to the public key — purely for human identification |
| `-f <path>` | Output path (default `~/.ssh/id_ed25519`) |
| `-N "<passphrase>"` | Set passphrase non-interactively. Empty `""` = no passphrase. |

The output is two files:
- `~/.ssh/id_ed25519` — private key (NEVER share, NEVER commit)
- `~/.ssh/id_ed25519.pub` — public key (safe to distribute)

## Required file permissions

SSH refuses to use keys with permissive permissions:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519           # private key
chmod 644 ~/.ssh/id_ed25519.pub       # public key
chmod 600 ~/.ssh/authorized_keys
chmod 600 ~/.ssh/config
```

| File | Mode | Why |
|---|---|---|
| `~/.ssh/` | `700` | Only owner reads/writes — protects the directory listing |
| Private key | `600` | Read/write owner only — `ssh` errors out otherwise |
| Public key | `644` | Readable by anyone — it's public by design |
| `authorized_keys` | `600` | Same protection as private keys; ssh-server checks this |

## Distribute the public key

### `ssh-copy-id` — the easy way

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@host
```

Reads the public key, appends it to `~/.ssh/authorized_keys` on the remote host, and sets
the right permissions. Requires password access for the first connection.

### Manual

```bash
cat ~/.ssh/id_ed25519.pub | ssh user@host 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

Useful when the remote has a custom SSH port or non-standard auth flow.

## Per-host config (`~/.ssh/config`)

```
Host github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_github

Host vm100
    HostName <tailscale-ip-vm100>
    User gpu
    IdentityFile ~/.ssh/id_ed25519

Host *.<tailnet-id>.ts.net
    User devops
    IdentityFile ~/.ssh/id_ed25519
```

| Directive | Purpose |
|---|---|
| `Host` | Pattern matched against the connection target. Supports wildcards. |
| `HostName` | Real hostname/IP if `Host` is just an alias |
| `User` | Default username for that host |
| `IdentityFile` | Which key to offer |
| `IdentitiesOnly yes` | Don't try other keys from ssh-agent — useful when you have many keys |
| `Port` | Non-standard SSH port |
| `ProxyJump` | Connect through a bastion host (`ssh -J`) |

After this, `ssh vm100` is enough — no flags needed.

## ssh-agent

Caches the unlocked private key in memory so you only enter the passphrase once per session.

```bash
eval "$(ssh-agent -s)"          # start agent in current shell
ssh-add ~/.ssh/id_ed25519       # add key (prompts for passphrase)
ssh-add -l                      # list loaded keys
ssh-add -D                      # remove all keys from the agent
```

Most distros start an agent per login session automatically. On systemd-managed desktops it's
usually `gnome-keyring` or `ssh-agent.socket`.

## Agent forwarding (use carefully)

```bash
ssh -A user@host
```

Forwards the agent socket to the remote host so that the remote host can use your local keys
(e.g., to `git push` from a build server). **Risk:** anyone with root on the remote can hijack
the forwarded socket and impersonate you to any host that trusts your key.

Safer alternative: use `ProxyJump` to bounce through the bastion without exposing your agent
on intermediate hosts.

## GitHub SSH authentication

```bash
# 1. Generate dedicated key
ssh-keygen -t ed25519 -C "nico-github" -f ~/.ssh/id_ed25519_github

# 2. Add the public key to GitHub
#    https://github.com/settings/keys → New SSH key → paste id_ed25519_github.pub

# 3. Add ~/.ssh/config entry for github.com (see above)

# 4. Test
ssh -T git@github.com
# Expected: "Hi <username>! You've successfully authenticated, but GitHub does not provide shell access."
```

Use a dedicated key per device/purpose so you can revoke without breaking everything else.

## known_hosts: trust on first use (TOFU)

When you connect to a new host:

```
The authenticity of host '<host>' can't be established.
ED25519 key fingerprint is SHA256:abc...
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

Saying yes appends the host's public key to `~/.ssh/known_hosts`. Future connections verify
against this — if the key changes, SSH refuses to connect (potential MITM).

| Operation | Command |
|---|---|
| Remove a stale entry | `ssh-keygen -R <hostname>` |
| Show all known hosts | `ssh-keygen -F <hostname>` |
| Get a host's key fingerprint without connecting | `ssh-keyscan -t ed25519 <host>` |

## When `host_key_checking=False` is acceptable

Ansible's default is to enforce known_hosts checking. For dynamic homelab inventories where
container IPs may rotate or where many hosts are added/removed, this becomes operational friction.

The trade-off:
- **Off:** First connection is implicitly trusted. Vulnerable to MITM if an attacker is on the
  network path during that first connection.
- **On:** First connection requires explicit acceptance. Painful when bulk-onboarding nodes.

In a Tailscale-only inventory, the network path is already encrypted and identity-verified at
the Tailscale layer — making `host_key_checking = False` a defensible default. Document it
explicitly so future-you doesn't wonder why MITM protection looks weakened.

## Revoking access

To remove a key from a server:

```bash
# Edit authorized_keys and delete the line containing the public key
ssh user@host "sed -i '/<key-comment-or-fingerprint>/d' ~/.ssh/authorized_keys"
```

For repo-managed access, regenerate keys when:
- A device is lost or sold
- A team member leaves
- You suspect compromise
- Annually as hygiene

## Related

- [Security: Least-Privilege Patterns](../security/least-privilege-patterns.md)
- [Networking: Tailscale](../networking/tailscale.md)
- [Linux: systemd Service Hardening](systemd-service-hardening.md)
