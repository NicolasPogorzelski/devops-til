# Private CA with OpenSSL - Certificates for Internal Services

## The model in four sentences

A certificate binds a public key to a name and is signed by a Certificate Authority (CA).
A client trusts a certificate when it trusts the CA that signed it - the chain is
`leaf -> CA`. Running an own CA means: one key pair that signs, one public certificate that
every client imports once, and per-service leaf certificates that clients accept
automatically because the CA is known. The private CA key is the whole security of the
system: whoever holds it can issue a valid certificate for *any* name the clients trust.

## Three files, three rules

| File | What it is | Rule |
|---|---|---|
| `ca.key` | private CA key | encrypted with a passphrase, stays on the workstation, never on a server, never in git |
| `ca.crt` | public CA certificate | distributed everywhere: browsers, servers, repo - it only lets clients *verify*, not *sign* |
| `<host>.key` + `<host>.crt` | service key and certificate | key **unencrypted** (the server process must read it unattended), protected by mode 600 and owner; only on the server that serves the name |

Publishing `ca.crt` in a repository is correct, not a leak. The one attack on a public CA
certificate is *replacement*: publish the SHA-256 fingerprint next to it so an import can be
verified (`openssl x509 -in ca.crt -noout -fingerprint -sha256`).

## Create the CA (once)

```bash
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -aes-256-cbc -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 3650 -subj "/CN=lab.test Root CA/O=lab.test" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" -out ca.crt
```

| Piece | Why |
|---|---|
| `genpkey -algorithm EC ... P-256` | modern default; ECDSA keys are small and fast, supported by every current client (Caddy, Java 17+, Ruby/OpenSSL, browsers). RSA 2048/4096 only for legacy clients |
| `-aes-256-cbc` | passphrase-encrypted key file - the CA key is the one file worth encrypting at rest |
| `req -x509` | self-signed: a root CA signs itself |
| `basicConstraints=critical,CA:TRUE,pathlen:0` | *is* a CA, may **not** issue sub-CAs; `critical` = a client that does not understand the extension must reject the certificate |
| `keyUsage=keyCertSign,cRLSign` | the key signs certificates and revocation lists, nothing else |
| `-days 3650` | renewing a CA means touching every trust store again |

## Issue a service certificate

```bash
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out git.lab.test.key   # no passphrase
openssl req -new -key git.lab.test.key -subj "/CN=git.lab.test" -out git.lab.test.csr
openssl x509 -req -in git.lab.test.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 -sha256 \
  -extfile <(printf 'subjectAltName=DNS:%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n' git.lab.test) \
  -out git.lab.test.crt
openssl verify -CAfile ca.crt git.lab.test.crt      # must print OK
```

| Piece | Why |
|---|---|
| CSR without extensions | the CA decides the extensions when signing - the requester cannot grant itself `CA:TRUE` |
| `subjectAltName=DNS:<host>` | **the only name modern clients check.** The CN is ignored. A certificate without SAN is rejected by every current browser - the most common openssl mistake |
| `extendedKeyUsage=serverAuth` | browsers require it for TLS servers |
| `keyUsage=digitalSignature` | sufficient for ECDSA; `keyEncipherment` is RSA key transport and would be wrong here |
| `-CAcreateserial` | every certificate of a CA needs a unique serial; `ca.srl` keeps the counter |
| `-days 365` | below the 397-day maximum browsers enforce for public CAs - keeping the convention forces a documented renewal routine |
| `-extfile <(printf ...)` | process substitution: the extension "file" is the output of `printf`, no temp file |

## The part that actually costs time: trust distribution

The browser is not the only client. Every service that calls another service over TLS is a
client with its own trust store, and each technology has its own place:

| Client | Where the CA goes |
|---|---|
| Fedora / Bazzite system | `/etc/pki/ca-trust/source/anchors/` + `update-ca-trust` |
| Debian / Ubuntu | `/usr/local/share/ca-certificates/*.crt` + `update-ca-certificates` |
| **Flatpak browsers** | do **not** read the system store - import in the browser's own certificate manager |
| Java (Tomcat, XWiki) | JVM `cacerts` via `keytool -importcert`, or a dedicated trust store |
| GitLab Omnibus | `/etc/gitlab/trusted-certs/` (symlinked into the embedded OpenSSL store on reconfigure) |
| Ruby / generic OpenSSL apps | `SSL_CERT_FILE` env var pointing at the CA |

The tempting shortcut for "unable to get local issuer certificate" is to disable
verification in the client (`verify_certificates: false`, `-k`, `insecure`). That makes TLS
between the services worthless; distribute the CA instead.

## Verification commands

```bash
openssl x509 -in cert.crt -noout -text                       # everything
openssl x509 -in cert.crt -noout -ext subjectAltName          # just the SAN
openssl verify -CAfile ca.crt cert.crt                        # chain
openssl s_client -connect host:443 -servername host </dev/null 2>/dev/null | openssl x509 -noout -dates
```

## Not done here, but standard in production

- **Root + intermediate:** the root stays offline and signs only an intermediate CA, which
  issues day-to-day certificates. Compromise of the intermediate is revocable without
  rebuilding every trust store.
- **Revocation (CRL/OCSP):** without it, a leaked service key stays valid until expiry; short
  validity is the pragmatic substitute in a small setup.
- **Key custody:** HSM or an encrypted offline medium for the root key.
