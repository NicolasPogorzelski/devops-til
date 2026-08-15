# Ansible Vault

## What it is

Ansible Vault is AES-256 symmetric encryption built into Ansible. It encrypts either entire YAML files or individual variable values. Ansible decrypts on-the-fly at playbook run time - no separate service required.

## The problem it solves

Without Vault, secrets end up in Git as plaintext:

```yaml
# group_vars/all/vars.yml - visible to everyone who clones the repo
db_password: "SuperSecret123"
discord_webhook: "https://discord.com/api/webhooks/..."
```

With Vault:

```yaml
db_password: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  38653262373932623861326437...
```

Only someone with the vault password can decrypt. The ciphertext in Git is useless without it.

## Why rotation after a leak is not enough

If a plaintext credential was ever committed to Git, it is permanently in the history - even after deletion and rotation:

```bash
git log -p --all | grep "db_password"
# finds the old password in a commit from 8 months ago
```

**Breach Window**: the time between when credentials were exposed and when they were rotated. What happened in that window is unknown:
- Backdoors may have been planted
- Data may have been exfiltrated
- Unknown database users may have been created

Rotation stops future damage. It does not undo past damage.

## Correct incident response after a credential leak

1. Rotate the credential immediately
2. Invalidate all active sessions
3. Check audit logs: who authenticated with the old credential and when
4. Check for unknown accounts (DB users, SSH keys, API tokens)
5. Clean Git history with `git filter-repo` - so future repo clones no longer contain the credential

`git filter-repo` replaces the deprecated `git filter-branch`. Note: history rewrite on a shared repo forces all collaborators to re-clone.

## Standard file layout with Vault

Split non-secret and secret variables into separate files per group:

```
ansible/
  group_vars/
    all/
      vars.yml       # non-secret variables, committed as plaintext
      vault.yml      # encrypted with ansible-vault, committed as ciphertext
```

Convention: prefix vault variable names with `vault_`, then reference them in `vars.yml`:

```yaml
# vars.yml
discord_webhook_url: "{{ vault_discord_webhook_url }}"

# vault.yml (encrypted)
vault_discord_webhook_url: "https://discord.com/api/webhooks/..."
```

This way, `vars.yml` is always readable and shows which variables exist - without exposing values.

## Key commands

```bash
# create a new encrypted file
ansible-vault create group_vars/all/vault.yml

# edit an existing encrypted file
ansible-vault edit group_vars/all/vault.yml

# encrypt an existing plaintext file
ansible-vault encrypt group_vars/all/vault.yml

# decrypt to stdout (for inspection, never leave decrypted on disk)
ansible-vault view group_vars/all/vault.yml

# run a playbook with vault decryption (prompts for password)
ansible-playbook playbooks/deploy.yml --ask-vault-pass

# run with a password file (for automation/CI)
ansible-playbook playbooks/deploy.yml --vault-password-file ~/.vault_pass
```

## Vault password file

For day-to-day use without typing the password every run:

```bash
echo "my-vault-password" > ~/.vault_pass
chmod 600 ~/.vault_pass
```

Reference it in `ansible.cfg` so it's used automatically:

```ini
[defaults]
vault_password_file = ~/.vault_pass
```

The password file must never be committed. Add to `.gitignore`:

```
.vault_pass
*.vault_pass
```

## Practical workflow: encrypt_string

For individual secrets inside a vars file (recommended for homelab - keeps files readable):

```bash
# encrypt a single value and print ready-to-paste YAML
ansible-vault encrypt_string 'my-secret-value' --name 'vault_db_password'
```

Output is valid YAML - paste directly into `group_vars/all/vault.yml`:

```yaml
vault_db_password: !vault |
          $ANSIBLE_VAULT;1.1;AES256
          38653262373932623861326437...
```

The `!vault` YAML tag tells Ansible to decrypt this value at runtime.

Verify decryption works before using in a playbook:

```bash
ansible all -m debug -a "var=vault_db_password" -l lxc211
```

## Role pattern with Vault

A role that deploys a `.env` file splits variables into three layers:

```
roles/myservice/
  defaults/main.yml     # non-secret defaults (plain YAML)
  templates/app.env.j2  # Jinja2 template referencing both layers
group_vars/all/
  vault.yml             # encrypted secrets only
```

`defaults/main.yml` - plain, readable:
```yaml
app_dbport: 5432
app_dbname: mydb
```

`vault.yml` - encrypted:
```yaml
vault_app_dbpass: !vault |
    $ANSIBLE_VAULT;1.1;AES256
    ...
```

`templates/app.env.j2` - bridges both:
```
APP_DBPORT={{ app_dbport }}
APP_DBPASS={{ vault_app_dbpass }}
```

The `.env` written to the node contains plaintext - Vault only protects the value in the repo and during transit. Access control on the target is a separate concern.

## What Vault does NOT protect

Vault protects secrets in your Ansible code and Git repo. It does not protect the deployed secret on the target server - the `.env` file or config file on disk remains plaintext. Access control on the target server is a separate concern.

## Vault IDs and the --ask-vault-pass conflict

Every Ansible Vault password source gets a label called a **vault ID**. When no ID is specified explicitly, Ansible assigns the label `default`.

Two sources produce two `default` IDs - Ansible cannot determine which to use for encryption:

```
vault_password_file = ~/.vault_pass   ->  vault ID: default
--ask-vault-pass                      ->  vault ID: default
```

Error:
```
[ERROR]: The vault-ids default,default are available to encrypt.
Specify the vault-id to encrypt with --encrypt-vault-id
```

**Fix:** do not combine `vault_password_file` (in `ansible.cfg`) with `--ask-vault-pass`. Use one or the other.

## Changing the vault password (inline vault format)

`ansible-vault rekey` works on whole encrypted files. It does **not** work on inline `!vault |` blocks inside a YAML file.

For inline vault, each value must be re-encrypted individually:

1. Read current plaintext values from a running node (Ansible decrypts on the fly):
   ```bash
   ansible lxc211 -m debug -a "var=vault_paperless_dbpass"
   ```

2. Update `~/.vault_pass` with the new password **first** - this avoids the vault-ID conflict:
   ```bash
   echo 'new-password' > ~/.vault_pass
   ```

3. Re-encrypt each value without `--ask-vault-pass` (Ansible reads the new password from `ansible.cfg` automatically):
   ```bash
   ansible-vault encrypt_string 'VALUE' --name 'vault_paperless_dbpass'
   ```

4. Rebuild `vault.yml` with the three new `!vault |` blocks.

5. Verify decryption and run the playbook to confirm idempotency.

## The !vault | YAML syntax

`!vault` is a YAML tag. It tells the YAML parser: "this is not a plain string - pass it to Ansible Vault for decryption." Without the tag, Ansible would treat the ciphertext as a literal string and never decrypt it.

`|` is the YAML block scalar operator. It preserves newlines in multi-line values. The AES256 ciphertext spans multiple lines, so `|` is required.

Together: `!vault |` = "multi-line encrypted value - decrypt at runtime."

## Where decryption happens

Decryption always happens on the **control node** (the machine running `ansible` or `ansible-playbook`), not on the target (managed node).

The managed node never sees:
- The vault password
- The encrypted ciphertext
- `~/.vault_pass` or `ansible.cfg`

It only receives the final plaintext value - either as a variable in memory, or written to a file by a task (e.g., a deployed `.env`).

## Official documentation

- Vault guide: https://docs.ansible.com/ansible/latest/vault_guide/index.html
- Encrypting content: https://docs.ansible.com/ansible/latest/vault_guide/vault_encrypting_content.html
- Using encrypted content in playbooks: https://docs.ansible.com/ansible/latest/vault_guide/vault_using_encrypted_content.html
