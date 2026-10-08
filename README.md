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
2. asks for the web port, the address users open Mintrix at, and your license key;
3. creates `/opt/mintrix` with `compose.yaml` and `.env`, using a new encryption key and random database passwords;
4. gets a registry login for your license key from the license server (only for an active license, for the domain it is bound to), and logs out again after the download;
5. downloads and starts Mintrix and its database;
6. fetches the license file for your license key and address (`/opt/mintrix/runtime/node.dat`);
7. creates the first administrator, `administrator` with the password `password`.

**Sign in and change that password and the account's email right away**: anyone who can reach the panel can try the default.

Without questions, for example from automation:

```sh
sudo sh install.sh --yes --url https://mintrix.example.com --license <key>
```

When the license server cannot give a login, the script asks for one. Without questions, set it beforehand: `export MINTRIX_REGISTRY_USER=<user> MINTRIX_REGISTRY_TOKEN=<token>` and run with `sudo -E`.

`sh install.sh --help` lists all options.

### Address and HTTPS

- An `http://` address makes Mintrix reachable on that port from the network. This is fine for trying it out, but logins and customer data then travel unencrypted.
- An `https://` address keeps Mintrix reachable only from the server itself, behind a reverse proxy with HTTPS on that server (Caddy, nginx). Point the proxy at `http://127.0.0.1:8000`.

The license is tied to the domain of this address, so set the final one before adding the license key. Ministra and new streaming servers (Servers > Install Server) call Mintrix at this address: they must be able to reach it.

## Update

```sh
sudo mintrix-update                      # the newest release
sudo mintrix-update --version 0.1.2      # a given version, also to go back
```

An update backs up the database to `/opt/mintrix/mysql_backups/` first, keeps `.env`, and replaces `compose.yaml`. Going back to an older version does not undo its database changes: restore the backup taken before the update.

## Settings

The settings are in `/opt/mintrix/.env`, and the comments there explain each one. After a change, apply it with `sudo mintrix-update --version <running version>`; this also fetches the license file after you add or change `MINTRIX_LICENSE_KEY`. Keep `.env` private and back it up with your database: a backup is only usable with the same `APP_KEY`.

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

