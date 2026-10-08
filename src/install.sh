#!/bin/sh
# Mintrix installer, version @@VERSION@@
#
#   wget https://github.com/@@REPO@@/releases/latest/download/install.sh
#   sudo sh install.sh
#
# Installs Docker when it is missing, then Mintrix into /opt/mintrix: settings with a new
# encryption key and random passwords, the images, the database and a first administrator.
# Run again (or run mintrix-update) to update: settings and data are kept, the database is
# backed up first. sh install.sh --help lists the options.
set -eu

VERSION="@@VERSION@@"
REPO="@@REPO@@"
# Checks the license key and gives the registry login for the images
LICENSE_SERVER="${MINTRIX_LICENSE_SERVER:-https://license.newiq.pl}"

dir=/opt/mintrix
app_url=
license_key=
port=
assume_yes=false

usage() {
    cat <<EOF
Mintrix installer $VERSION

Usage: sudo sh install.sh [options]

  --version VERSION   Install this version instead of $VERSION
  --dir DIR           Installation folder (default: /opt/mintrix)
  --url URL           Address users open Mintrix at, e.g. https://mintrix.example.com
  --license KEY       License key, from your client area
  --port PORT         Web port (default: 8000)
  --yes               Ask nothing; use the options above and the defaults

The license key is checked with the license server on every run, before the download.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --dir) dir="${2:?--dir needs a value}"; shift 2 ;;
        --url) app_url="${2:?--url needs a value}"; shift 2 ;;
        --license) license_key="${2:?--license needs a value}"; shift 2 ;;
        --port) port="${2:?--port needs a value}"; shift 2 ;;
        --yes|-y) assume_yes=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
    esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# Questions come from the terminal, so they also work when this script is piped into sh
interactive() { [ "$assume_yes" = false ] && [ -r /dev/tty ] && [ -w /dev/tty ] && { : </dev/tty; } 2>/dev/null; }

# ask VARIABLE "Question" default
ask() {
    if interactive; then
        printf '%s [%s]: ' "$2" "$3" >/dev/tty
        read -r answer </dev/tty || answer=
        eval "$1=\${answer:-\$3}"
    else
        eval "$1=\$3"
    fi
}

download() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
    else fail "Neither curl nor wget is installed."
    fi
}

# Sets KEY=value in .env, in place when the key exists
set_env() {
    tmp=$(mktemp)
    awk -v key="$1" -v value="$2" '
        index($0, key "=") == 1 { print key "=" value; done = 1; next }
        { print }
        END { if (!done) print key "=" value }
    ' "$dir/.env" > "$tmp"
    cat "$tmp" > "$dir/.env"
    rm -f "$tmp"
}

get_env() { sed -n "s/^$1=//p" "$dir/.env" | tail -n 1; }

random() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; }

compose() { docker compose --project-directory "$dir" -f "$dir/compose.yaml" "$@"; }

# ---------------------------------------------------------------- checks

printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$' \
    || fail "Not a version: $VERSION"
[ "$(uname -s)" = Linux ] || fail "Mintrix installs on Linux servers only."
case "$(uname -m)" in
    x86_64|amd64) ;;
    *) fail "Mintrix needs an x86-64 server; this one is $(uname -m)." ;;
esac
[ "$(id -u)" = 0 ] || fail "Run as root: sudo sh $0"

# ---------------------------------------------------------------- Docker

if ! command -v docker >/dev/null 2>&1; then
    say "Installing Docker"
    tmp=$(mktemp)
    download https://get.docker.com "$tmp"
    sh "$tmp"
    rm -f "$tmp"
fi

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl enable --now docker >/dev/null 2>&1 || true
fi

if ! docker compose version >/dev/null 2>&1; then
    say "Installing the Docker Compose plugin"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q docker-compose-plugin
    fi
    docker compose version >/dev/null 2>&1 \
        || fail "Install the Docker Compose plugin: https://docs.docker.com/compose/install/linux/"
fi

docker info >/dev/null 2>&1 || fail "Docker is installed but not running. Start it (systemctl start docker) and run this again."

# ---------------------------------------------------------------- files

mkdir -p "$dir/mysql_backups" "$dir/runtime"
chmod 700 "$dir"

# compose.yaml belongs to the installer and is replaced on every run
cat > "$dir/compose.yaml" <<'MINTRIX_COMPOSE_EOF'
@@COMPOSE_YAML@@
MINTRIX_COMPOSE_EOF

if [ -f "$dir/.env" ]; then
    fresh=false
    previous=$(get_env MINTRIX_VERSION)
    say "Updating Mintrix in $dir${previous:+ from $previous} to $VERSION (settings in .env are kept)"
    # The images moved from the momodeluxe to the newiqllc registry: new versions are only there
    for key in MINTRIX_IMAGE MINTRIX_WEB_IMAGE; do
        image=$(get_env "$key")
        case "$image" in
            ghcr.io/momodeluxe/*) set_env "$key" "ghcr.io/newiqllc/${image#ghcr.io/momodeluxe/}" ;;
        esac
    done
else
    fresh=true
    previous=
    say "Installing Mintrix $VERSION into $dir"

    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    ask port "Web port" "${port:-8000}"
    ask app_url "Address users open Mintrix at" "${app_url:-http://${ip:-127.0.0.1}:$port}"

    case "$app_url" in
        # Behind a reverse proxy with HTTPS on this machine: not reachable from outside
        https://*) bind=127.0.0.1 ;;
        *) bind=0.0.0.0 ;;
    esac

    cat > "$dir/.env" <<'MINTRIX_ENV_EOF'
@@ENV_EXAMPLE@@
MINTRIX_ENV_EOF
    chmod 600 "$dir/.env"
    set_env APP_KEY "base64:$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
    set_env DB_PASSWORD "$(random)"
    set_env DB_ROOT_PASSWORD "$(random)"
    set_env APP_URL "$app_url"
    set_env MINTRIX_HTTP_BIND "$bind"
    set_env MINTRIX_HTTP_PORT "$port"
fi

# ---------------------------------------------------------------- license

# The host of APP_URL: the domain the license is bound to, as Mintrix itself sends it
license_domain() {
    get_env APP_URL | sed -e 's#^[A-Za-z][A-Za-z0-9+.-]*://##' -e 's#[/?\#].*##' -e 's#^.*@##' -e 's#:[0-9]*$##' \
        | tr '[:upper:]' '[:lower:]'
}

# A string field of the license server's flat JSON answer
json_field() { sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" "$2"; }

# Checks license key $1 for the domain of APP_URL with the license server: sets registry,
# user and token (the login for the images) when it is accepted, says why not otherwise
license_login() {
    key=$1
    domain=$(license_domain)
    printf '%s' "$key" | grep -Eq '^[A-Za-z0-9-]+$' || { echo "That is not a license key."; return 1; }
    printf '%s' "$domain" | grep -Eq '^[a-z0-9.-]+$' || { echo "APP_URL in $dir/.env has no usable domain."; return 1; }

    answer=$(mktemp)
    url="${LICENSE_SERVER%/}/registry.php"
    # Over IPv4: the license is bound to this server's IPv4 address
    if command -v curl >/dev/null 2>&1; then
        curl -4 -sS --max-time 30 -o "$answer" --data "licensekey=$key&domain=$domain" "$url" || true
    else
        wget -4 -q --content-on-error -T 30 -O "$answer" --post-data "licensekey=$key&domain=$domain" "$url" || true
    fi
    registry=$(json_field registry "$answer")
    user=$(json_field user "$answer")
    token=$(json_field token "$answer")
    error=$(json_field error "$answer")
    rm -f "$answer"

    [ -n "$registry" ] && [ -n "$user" ] && [ -n "$token" ] && return 0
    echo "License key not accepted for $domain: ${error:-the license server could not be reached ($LICENSE_SERVER)}"
    return 1
}

# Asked on every run, new install or update, with the current key (or --license) as the
# default, and checked before anything is downloaded: only a key the license server
# accepts is saved in .env, and its answer is the login for the images.
say "Checking the license key"
[ -n "$license_key" ] || license_key=$(get_env MINTRIX_LICENSE_KEY)
while :; do
    if interactive; then
        ask license_key "License key (from your client area)" "$license_key"
    fi
    if [ -z "$license_key" ]; then
        interactive || fail "Mintrix needs a license key: run again with --license KEY (from your client area)."
        echo "A license key is required."
        continue
    fi
    license_login "$license_key" && break
    interactive || fail "Check the license key and APP_URL in $dir/.env, then run this again."
done
set_env MINTRIX_LICENSE_KEY "$license_key"
echo "License key accepted for $domain."

# ---------------------------------------------------------------- images

registry_logout() { docker logout "$registry" >/dev/null 2>&1 || true; }

say "Downloading Mintrix $VERSION"
# Pulled before anything changes: a wrong version stops here.
# MINTRIX_SKIP_PULL=1 is only for testing images loaded on this machine.
if [ "${MINTRIX_SKIP_PULL:-}" = 1 ]; then
    echo "Skipped (MINTRIX_SKIP_PULL=1)"
else
    # The login only lasts for the pull, so the token is not left in Docker's config
    trap registry_logout EXIT
    printf '%s' "$token" | docker login "$registry" -u "$user" --password-stdin >/dev/null \
        || fail "$registry refused the login from the license server."
    MINTRIX_VERSION="$VERSION" compose pull --quiet nginx app mysql \
        || fail "Could not download Mintrix $VERSION. Check the version: https://github.com/$REPO/releases"
    registry_logout
    trap - EXIT
fi

if compose ps --status running --services 2>/dev/null | grep -qx mysql; then
    backup="mysql_backups/$(date +%Y%m%d-%H%M%S)-before-$VERSION.sql.gz"
    say "Backing up the database to $dir/$backup"
    # shellcheck disable=SC2016  # expanded inside the MySQL container
    compose exec -T mysql sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers "$MYSQL_DATABASE"' 2>/dev/null \
        | gzip > "$dir/$backup"
fi

set_env MINTRIX_VERSION "$VERSION"

say "Starting Mintrix (the first start and database updates can take a few minutes)"
compose up -d --remove-orphans --wait --wait-timeout 600 \
    || fail "Mintrix did not become ready. See: cd $dir && docker compose logs --tail=100 app"

# The licensed features run only with the license file runtime/node.dat, issued for the
# license key and the domain of APP_URL. Fetched now rather than by the hourly scheduler.
say "Checking the license"
if compose exec -T app setpriv --reuid=www-data --regid=www-data --init-groups php artisan mintrix:status --sync; then
    # The queue worker and scheduler may have started before the file was there
    compose restart queue scheduler >/dev/null
else
    echo "The license file could not be fetched; the licensed features stay off until it is."
    echo "Check MINTRIX_LICENSE_KEY and APP_URL in $dir/.env, then run: mintrix-update --version $VERSION"
fi

# Only while no administrator exists: running this again never resets a password
sign_in="administrator / password   (change the password and email right away)"
if ! compose exec -T app php artisan mintrix:create-admin --default; then
    sign_in="with an administrator from: cd $dir && docker compose exec app php artisan mintrix:create-admin"
    echo "No default administrator created. Create one with: cd $dir && docker compose exec app php artisan mintrix:create-admin"
fi

# ---------------------------------------------------------------- mintrix-update

cat > /usr/local/bin/mintrix-update <<EOF
#!/bin/sh
# Updates Mintrix in $dir to the newest release: mintrix-update
# or to a given version:                          mintrix-update --version 1.2.3
set -eu
tmp=\$(mktemp)
trap 'rm -f "\$tmp"' EXIT
url=https://github.com/$REPO/releases/latest/download/install.sh
if command -v curl >/dev/null 2>&1; then curl -fsSL "\$url" -o "\$tmp"; else wget -qO "\$tmp" "\$url"; fi
sh "\$tmp" --dir "$dir" "\$@"
EOF
chmod 755 /usr/local/bin/mintrix-update

# ---------------------------------------------------------------- done

url=$(get_env APP_URL)
if [ "$fresh" = true ]; then
    cat <<EOF

Mintrix $VERSION is installed.

  Open:      ${url%/}/app/
  Sign in:   $sign_in
  Settings:  $dir/.env   (after a change, run: mintrix-update --version $VERSION)
  Update:    mintrix-update

EOF
    case "$url" in
        https://*) echo "Point your reverse proxy (HTTPS) at http://127.0.0.1:$(get_env MINTRIX_HTTP_PORT)." ;;
        *) echo "Mintrix is reachable without HTTPS. For use over the internet, set up a domain with HTTPS (see README)." ;;
    esac
else
    echo
    echo "Mintrix $VERSION is running${previous:+ (was $previous)}."
fi
