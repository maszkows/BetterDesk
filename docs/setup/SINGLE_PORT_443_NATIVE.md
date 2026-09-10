# Native RustDesk over one public port 443

This runbook installs BetterDesk on a dedicated Ubuntu VPS and exposes the web
console plus native RustDesk desktop signal and relay traffic through one
public port: **TCP 443**.

It documents a configuration tested with BetterDesk **3.5.92**, commit
`76a70a31175c962857e577982f5ac19d031e69a5`. At the time of testing, the fixes
needed for WSS-only relay were newer than the latest stable release, so this
runbook pins a known commit instead of following a moving branch during the
initial installation.

> This is a relay-only desktop-client setup. It deliberately does not expose
> BetterDesk's ordinary TCP/UDP ports to the Internet. Test it before replacing
> a production RustDesk deployment.

## Resulting architecture

```text
Internet TCP 443
       |
       v
Caddy: TLS termination
       |-- /ws/id*    -> 127.0.0.1:21118  native signal WSS
       |-- /ws/relay* -> 127.0.0.1:21119  native relay WSS
       |-- /healthz   -> 200
       `-- everything -> 127.0.0.1:5000   BetterDesk console
```

BetterDesk still opens internal listeners. UFW is what makes 443 the only
public BetterDesk port. Existing SSH, VPN, monitoring, or application firewall
rules are left untouched.

## Important limitation

Native desktop WSS and browser **Web Remote** both use `/ws/relay`, but require
different upstreams. This single-host configuration assigns `/ws/relay` to the
native RustDesk relay on port 21119. Web Remote therefore cannot share this
hostname. Use a second hostname/vhost if both features are required; see
[External Reverse Proxy Guide](REVERSE_PROXY.md#separate-hostnames-recommended-when-both-web-remote-and-native-wss-are-needed).

## Prerequisites

- A dedicated Ubuntu VPS with root/sudo access. Ubuntu 20.04 and x86_64 were
  used for the documented test.
- At least 1 vCPU, 2 GiB RAM, and roughly 10 GiB free disk for a source build.
- A DNS hostname, for example `desk.example.com`, with an A/AAAA record pointing
  directly to the VPS.
- Inbound TCP 443 allowed by the provider firewall/security group.
- TCP 22 or another known management path kept open before changing UFW.
- A backup of any existing RustDesk keys and database.

Do not proxy the DNS record through a service that terminates or rewrites the
connection during initial validation. A direct/DNS-only record is the easiest
baseline.

## 1. Set the installation variables

Run these commands in the SSH shell, replacing the hostname:

```bash
export BETTERDESK_DOMAIN=desk.example.com
export BETTERDESK_COMMIT=76a70a31175c962857e577982f5ac19d031e69a5
```

Confirm DNS before continuing:

```bash
getent ahosts "$BETTERDESK_DOMAIN"
```

## 2. Back up an existing RustDesk deployment

Skip this section only on a truly new VPS. Adjust paths if your existing
installation differs.

```bash
sudo install -d -m 700 /root/rustdesk-before-betterdesk
sudo cp -a /root/id_ed25519 /root/id_ed25519.pub \
  /root/db_v2.sqlite3 /root/rustdesk-before-betterdesk/ 2>/dev/null || true
sudo cp -a /etc/systemd/system/rustdesk-hbbs.service \
  /etc/systemd/system/rustdesk-hbbr.service \
  /root/rustdesk-before-betterdesk/ 2>/dev/null || true
```

Preserving `id_ed25519` keeps the same public server key, so enrolled clients
do not need a key change. Never publish or transmit the private key.

## 3. Install base dependencies

Use Node.js 22 LTS. On Ubuntu 20.04, GCC 10 is also needed for the native
SQLite module workaround described below.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git gnupg sqlite3 gcc-10 g++-10
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version
```

Install Caddy from its official Debian repository:

```bash
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update
sudo apt-get install -y caddy
```

## 4. Install the pinned BetterDesk build

```bash
cd /opt
sudo git clone https://github.com/UNITRONIX/BetterDesk.git betterdesk-src
cd /opt/betterdesk-src
sudo git checkout "$BETTERDESK_COMMIT"
sudo ./betterdesk.sh --auto --relay-servers "$BETTERDESK_DOMAIN"
```

The installer may open BetterDesk's default ports. Do not close them until the
services and SSH access have been checked; the firewall is hardened in step 7.

If migrating from RustDesk OSS, copy the old key and database only while both
old and new services are stopped, then run the installer's migration/repair
flow. Verify the key fingerprint before starting clients.

## 5. Ubuntu 20.04: rebuild `better-sqlite3`

On Ubuntu 20.04, the bundled `better-sqlite3` 13.0.3 Linux prebuild can require
newer GLIBC/GLIBCXX symbols. Typical symptoms are a failing
`betterdesk-console` service and an error mentioning `GLIBC_2.33`,
`GLIBC_2.34`, or `GLIBCXX_3.4.29`.

Apply this workaround on Ubuntu 20.04:

```bash
sudo rm -f /opt/BetterDeskConsole/node_modules/better-sqlite3/prebuilds/linux-x64.node
cd /opt/BetterDeskConsole/node_modules/better-sqlite3
sudo env CC=gcc-10 CXX=g++-10 npm run build-release
sudo systemctl restart betterdesk-console
```

Do not replace system glibc to solve this. A local native-module build is much
safer.

## 6. Apply the one-port configuration

The helper script is intentionally separate from the main installer. It:

- backs up the BetterDesk `.env`, both systemd units, and existing Caddyfile;
- makes Caddy the only TLS endpoint;
- configures trusted localhost proxy headers;
- sets public client endpoints to the chosen hostname;
- enables relay-only behavior;
- installs the provided Caddy template and restarts the three services.

It replaces `/etc/caddy/Caddyfile`, so use it only on a dedicated Caddy host or
merge [the template](../../contrib/single-port-443/Caddyfile.example) manually
when other sites already exist.

```bash
cd /opt/betterdesk-src
sudo BETTERDESK_DOMAIN="$BETTERDESK_DOMAIN" REPLACE_CADDYFILE=Y \
  bash ./contrib/single-port-443/configure-one-port-443.sh
```

The script prints the timestamped rollback directory under `/root`.

Why port 80 can remain closed: the supplied Caddyfile disables HTTP redirects
and the ACME HTTP challenge. Caddy obtains the certificate with TLS-ALPN-01 on
TCP 443. HTTP/3 is not enabled in this template, so UDP 443 is not required.

## 7. Restrict BetterDesk to public TCP 443

First preserve management access and open 443:

```bash
sudo ufw allow 22/tcp
sudo ufw allow 443/tcp comment 'BetterDesk WSS via Caddy'
sudo ufw enable
```

Remove only BetterDesk rules that the installer added. A command may report
that a rule does not exist; inspect the final rule list instead of resetting
the firewall.

```bash
for port in 21114 21115 21116 21117 21118 21119 21121 21122 5000 5443; do
  sudo ufw delete allow "${port}/tcp" || true
done
sudo ufw delete allow 21116/udp || true
sudo ufw status numbered
```

Provider-level firewalls/security groups must enforce the same policy. Keep
any unrelated ports that your VPS actually needs.

## 8. Retrieve credentials and configure clients

Show the generated administrator credentials locally on the VPS:

```bash
sudo betterdesk-show-admin-credentials
sudo cat /opt/betterdesk/id_ed25519.pub
```

Open the panel at `https://desk.example.com` and change the generated admin
password.

Configure every native RustDesk client as follows:

| Client field | Value |
|---|---|
| ID server | `desk.example.com` |
| Relay server | empty, or the same hostname if the client requires a value |
| API server | `https://desk.example.com` |
| Key | contents of `/opt/betterdesk/id_ed25519.pub` |
| Use WebSocket / `allow-websocket` | enabled / `Y` |

Do not enter `ws://`, `wss://`, `/ws/id`, or `:443` in the ID server field.
Restart the RustDesk application or service completely after changing its
network settings. For the first end-to-end test, use WebSocket mode on both
peers.

## 9. Verify the deployment

### On the VPS

```bash
sudo systemctl is-active betterdesk-server betterdesk-console caddy
sudo caddy validate --config /etc/caddy/Caddyfile
curl -fsS "https://${BETTERDESK_DOMAIN}/healthz"
curl -sSI "https://${BETTERDESK_DOMAIN}/" | head
sudo ss -lntup | grep -E ':(443|5000|2111[4-9]|2112[12])\b'
sudo ufw status numbered
```

The `ss` command will show internal BetterDesk listeners; that is expected.
UFW and an external port test determine public exposure.

Check both WebSocket upgrades:

```bash
for path in ws/id ws/relay; do
  curl --http1.1 --max-time 3 -i -N \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "https://${BETTERDESK_DOMAIN}/${path}" | head -n 1
done
```

Expected for both paths: `HTTP/1.1 101 Switching Protocols`.

### From a different Internet connection

```bash
nc -vz desk.example.com 443
for port in 21114 21115 21116 21117 21118 21119 21121 21122 5000 5443; do
  nc -vz -w 2 desk.example.com "$port"
done
```

Only 443 should connect. Finally, confirm all four functional outcomes:

1. Sign in to the HTTPS panel.
2. Confirm both RustDesk peers are online and have IDs.
3. Start a remote-control session between two WSS-configured peers.
4. Confirm the session uses relay and remains stable for several minutes.

Registration alone is not a complete relay test.

## Troubleshooting

| Symptom | Check |
|---|---|
| Panel returns 502 | `systemctl status betterdesk-console`; apply the Ubuntu 20.04 SQLite rebuild if symbols are missing |
| Certificate is not issued | DNS must point directly to the VPS and public TCP 443 must reach Caddy |
| `/ws/id` or `/ws/relay` is not 101 | Validate route order and ensure ports 21118/21119 listen locally |
| Client registers but cannot connect | Both peers need WebSocket mode; verify `TRUST_PROXY`, `TRUSTED_PROXIES`, and test `/ws/relay` |
| Client reports HTTP 308 | Do not configure a literal `ws://` URL; use the hostname and enable WebSocket mode |
| Client asks for a different key | Restore the original `id_ed25519` pair or deploy the new public key to all clients |
| Web Remote stops at relay | This hostname assigns `/ws/relay` to native WSS; use a second hostname for Web Remote |

Useful logs:

```bash
sudo journalctl -u betterdesk-server -u betterdesk-console -u caddy \
  --since '30 minutes ago' --no-pager
```

## Updates

This tested configuration starts from a fixed commit while the installed
`.env` uses `UPDATE_GITHUB_BRANCH=dev`. A panel update therefore follows the
current development branch, not the pinned commit.

Before every update:

1. Back up `/opt/betterdesk`, `/opt/BetterDeskConsole`, both systemd units, and
   `/etc/caddy/Caddyfile`.
2. Record the currently running version and Git commit.
3. Review upstream changes, especially signal, relay, installer, and database
   migrations.
4. Expect the installer to restore default ports or TLS options. Re-run the
   one-port helper and firewall audit after the update.
5. Repeat the complete verification section, including a real two-peer relay
   session.

Switch `UPDATE_GITHUB_BRANCH` to `main` only after a stable release contains
the WSS-only relay fixes you need and has passed the same tests.

## Rollback

The helper creates a backup directory such as:

```text
/root/betterdesk-one-port-443-preconfig-YYYYMMDDTHHMMSSZ/
```

To restore its configuration snapshot:

```bash
export BACKUP_DIR=/root/betterdesk-one-port-443-preconfig-YYYYMMDDTHHMMSSZ
sudo systemctl stop betterdesk-server betterdesk-console caddy
sudo cp -a "$BACKUP_DIR/.env" /opt/BetterDeskConsole/.env
sudo cp -a "$BACKUP_DIR/betterdesk-server.service" \
  /etc/systemd/system/betterdesk-server.service
sudo cp -a "$BACKUP_DIR/betterdesk-console.service" \
  /etc/systemd/system/betterdesk-console.service
sudo cp -a "$BACKUP_DIR/Caddyfile" /etc/caddy/Caddyfile
sudo systemctl daemon-reload
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl restart betterdesk-server betterdesk-console caddy
```

Firewall changes are not included in this snapshot. Restore only the exact
rules required by the previous deployment, preserving SSH access.

## Security checklist

- Change the generated admin password and keep the credential file private.
- Never publish `id_ed25519`, `.api_key`, `.env`, databases, backups, real IPs,
  hostnames, SSH usernames, or local key paths.
- Keep `TRUSTED_PROXIES` restricted to localhost for a same-host Caddy setup.
- Use enrollment approval or a managed enrollment policy after initial tests.
- Keep SSH and Caddy patched, and monitor service logs for repeated failures.
- Back up the server key and both databases off-host using encrypted storage.

## Related files

- [Caddy template](../../contrib/single-port-443/Caddyfile.example)
- [Configuration helper](../../contrib/single-port-443/configure-one-port-443.sh)
- [External Reverse Proxy Guide](REVERSE_PROXY.md)
- [RustDesk Client Deployment](RUSTDESK_CLIENT_DEPLOYMENT.md)
