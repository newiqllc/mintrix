# Mintrix installer

Mintrix is the management panel for the Ministra TV platform. This repository builds its installer: one script that sets up Docker and Mintrix on a server.

## Install

On a Linux server (x86-64, 2 GB RAM or more) with Ubuntu, Debian, RHEL, AlmaLinux, Rocky Linux or Fedora:

```sh
wget https://github.com/newiqllc/mintrix/releases/latest/download/install.sh
sudo sh install.sh
```

The script:

1. installs Docker Engine and the Compose plugin when they are missing;
2. creates `/opt/mintrix` with `compose.yaml` and `.env`, using a new encryption key and random database passwords;
3. asks for your license key and the domain it is for (on every run; the saved ones are the defaults) and checks them with the license server: only an active license for that domain is accepted and saved. A new license is tied to the domain on this first check. The answer is the login for the download, logged out again afterwards;
4. on a new installation, asks for the port Mintrix listens on (default 80) and whether users open it over HTTPS;
5. downloads and starts Mintrix and its database;
6. fetches the license file for your license and domain (`/opt/mintrix/runtime/node.dat`);
7. creates the first administrator, `administrator` with the password `password`.

**Sign in and change that password and the account's email right away**: anyone who can reach the panel can try the default.

Without questions, for example from automation:

```sh
sudo sh install.sh --yes --license <key> --domain tv.example.com            # https://, Cloudflare in front
sudo sh install.sh --yes --license <key> --domain tv.example.com --http     # plain http://
```

A key and domain the license server refuses are asked for again, with the reason; with `--yes` the script stops and says why. No other login is needed.

`sh install.sh --help` lists all options.

### Domain and HTTPS

Mintrix needs a domain name (e.g. `tv.example.com`), not an IP address: the license and its license file are locked to it. Point the domain's DNS at the server; the script only warns when it does not yet.

Mintrix listens for HTTP on port 80 and for HTTPS on port 443, both open to the network. The installer asks for both (8080 and 8443 are offered when 80 or 443 is taken).

| Setup | Cloudflare SSL/TLS mode |
|---|---|
| Cloudflare in front, Cloudflare Origin Certificate in `certs/` | **Full (strict)**: encrypted and checked all the way |
| Cloudflare in front, self-signed certificate (none added) | **Full** |
| Cloudflare in front, over HTTP only | **Flexible** (plain HTTP between Cloudflare and the server) |
| No proxy, your own certificate in `certs/` | — |

#### Ports

Set in `/opt/mintrix/.env`, then applied in `/opt/mintrix` with `sudo docker compose up -d`:

```sh
MINTRIX_HTTP_PORT=80
MINTRIX_HTTPS_PORT=443
MINTRIX_HTTP_BIND=            # empty: every address (IPv4 and IPv6); 127.0.0.1: this server only
MINTRIX_HTTPS_BIND=           # 127.0.0.1 also keeps HTTPS (or HTTP) from being reached at all
```

`mintrix-update --port <port> --https-port <port>` does the same and checks the ports are free.

With `--http`, users open `http://<domain>` directly: fine for trying it out, but logins and customer data then travel unencrypted.

#### Certificate

Put the certificate (with its intermediate chain appended) and its key in `/opt/mintrix/certs/` as `mintrix.crt` and `mintrix.key`, then run `sudo docker compose restart nginx` in `/opt/mintrix`. Any certificate works: a free Cloudflare Origin Certificate (SSL/TLS > Origin Server, valid up to 15 years), a bought one, or Let's Encrypt. Without one, Mintrix serves a self-signed certificate; with one that is expired or does not match its key, it serves the self-signed one too and says why in `docker compose logs nginx`. It also warns there two weeks before the certificate expires.

#### Behind Cloudflare or another proxy

Set `MINTRIX_TRUSTED_PROXIES=cloudflare` in `.env` (the installer asks), or your proxy's addresses, so Mintrix sees each visitor's own IP address (sign-in limits, IP whitelist, logs). Allow ports 80 and 443 only from Cloudflare's addresses in the server's firewall, so nobody bypasses it.

To move to another domain, reissue the license in your client area, then run `mintrix-update` and enter the new domain. Ministra and new streaming servers (Servers > Install Server) call Mintrix at its address: they must be able to reach it.

## Update

```sh
sudo mintrix-update                      # the newest release
sudo mintrix-update --version 0.1.2      # a given version, also to go back
```

An update backs up the database to `/opt/mintrix/mysql_backups/` first, keeps `.env`, and replaces `compose.yaml`. Going back to an older version does not undo its database changes: restore the backup taken before the update.

## Reinstall

To start again from scratch. **This deletes the database and all data of the installation**; keep a backup from `/opt/mintrix/mysql_backups/` if you may need it.

```sh
cd /opt/mintrix && sudo docker compose down -v --remove-orphans
sudo rm -rf /opt/mintrix /usr/local/bin/mintrix-update
```

Then install as above. Without removing `/opt/mintrix`, the script finds its `.env` and updates instead.

## Settings

The settings are in `/opt/mintrix/.env`, and the comments there explain each one. After a change, apply it with `sudo mintrix-update --version <running version>`; this also fetches the license file after you add or change `MINTRIX_LICENSE_KEY`. Keep `.env` private and back it up with your database: a backup is only usable with the same `APP_KEY`.

### Your own changes

`compose.yaml` is replaced on every update. Keep your changes in files the update never touches:

- `/opt/mintrix/compose.override.yaml`: merged into `compose.yaml` (extra ports, volumes or services).
- `/opt/mintrix/nginx/*.conf`: added inside Mintrix's nginx server block (extra headers, `allow`/`deny` rules, locations).

Apply them in `/opt/mintrix` with `sudo docker compose up -d`.

## Administrator accounts

```sh
cd /opt/mintrix
docker compose exec app php artisan mintrix:create-admin            # another administrator
docker compose exec app php artisan mintrix:2fa-reset <email>       # reset two-factor authentication
```

## Releasing (maintainers)

The Mintrix release workflow starts `.github/workflows/release.yml` here once a version's images are pushed. It builds `dist/install.sh` from `src/install.sh`, writes `src/compose.yaml`, `src/env.example` and the version into it, checks it, and attaches it to a release `v<version>`. To build one locally:

```sh
sh build.sh 0.1.0
```

To test an installer against images loaded on the machine instead of downloaded, set `MINTRIX_SKIP_PULL=1`.

