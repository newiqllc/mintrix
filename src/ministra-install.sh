#!/bin/sh
# Ministra installer, version @@VERSION@@
#
#   wget https://github.com/@@REPO@@/releases/latest/download/ministra-install.sh
#   sudo sh ministra-install.sh
#
# Installs Docker when it is missing, then Ministra into /opt/ministra: settings with random
# passwords, the images, the database. Ministra is installed for a Mintrix installation:
# that Mintrix authorizes the download (with its license) and says which Ministra version
# to run, and Ministra sends its change notifications there.
# Run again (or run ministra-update) to update: settings and data are kept, the database is
# backed up first. sh ministra-install.sh --help lists the options.
set -eu

INSTALLER_VERSION="@@VERSION@@"
REPO="@@REPO@@"

dir=/opt/ministra
version=
mintrix_url=
api_key=
port=
assume_yes=false
force=false

usage() {
    cat <<EOF
Ministra installer $INSTALLER_VERSION

Usage: sudo sh ministra-install.sh [options]

  --mintrix URL       Address of your Mintrix installation, e.g. https://panel.example.com
  --api-key KEY       Its Inbound API Key (Mintrix > Settings > Ministra)
  --version VERSION   Install this Ministra version instead of the one Mintrix names
  --dir DIR           Installation folder (default: /opt/ministra)
  --port PORT         Port the portal listens on, open to the network (default: 80, or
                      8080 when 80 is taken)
  --yes               Ask nothing; use the options above and the defaults
  --force             Allow going back to an older Ministra version (its database is
                      not changed back: restore a backup from mysql_backups/ if needed)

Mintrix checks the API key and its own license on every run, before the download.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mintrix) mintrix_url="${2:?--mintrix needs a value}"; shift 2 ;;
        --api-key) api_key="${2:?--api-key needs a value}"; shift 2 ;;
        --version) version="${2:?--version needs a value}"; shift 2 ;;
        --dir) dir="${2:?--dir needs a value}"; shift 2 ;;
        --port) port="${2:?--port needs a value}"; shift 2 ;;
        --yes|-y) assume_yes=true; shift ;;
        --force) force=true; shift ;;
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

# compose.mintrix.yaml (written below while Mintrix runs on this server) and
# compose.override.yaml (yours: kept across updates) are merged in when they exist
compose() {
    files="-f $dir/compose.yaml"
    [ ! -f "$dir/compose.mintrix.yaml" ] || files="$files -f $dir/compose.mintrix.yaml"
    [ ! -f "$dir/compose.override.yaml" ] || files="$files -f $dir/compose.override.yaml"
    # shellcheck disable=SC2086  # $dir has no spaces (checked below)
    docker compose --project-directory "$dir" $files "$@"
}

# Whether something on this server listens on TCP port $1 (unknown without ss: no)
port_in_use() {
    command -v ss >/dev/null 2>&1 && [ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]
}

valid_version() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$'; }

# Whether version $1 is older than version $2 (both valid): 0.2.0-beta.1 < 0.2.0 < 0.2.1
version_older() {
    awk -v a="$1" -v b="$2" '
        # major, minor, patch; then the release itself above any prerelease of it
        # (rank 9), and alpha < beta < rc with their number
        function key(v,   n, parts, core, pre, rank, num) {
            n = split(v, parts, "-")
            split(parts[1], core, ".")
            rank = 9; num = 0
            if (n > 1) {
                split(parts[2], pre, ".")
                rank = (pre[1] == "alpha") ? 1 : (pre[1] == "beta") ? 2 : 3
                num = pre[2]
            }
            return sprintf("%09d%09d%09d%d%09d", core[1], core[2], core[3], rank, num)
        }
        BEGIN { exit !(key(a) < key(b)) }
    '
}

# A string field of a flat JSON answer
json_field() { sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" "$2"; }

# ---------------------------------------------------------------- checks

[ "$(uname -s)" = Linux ] || fail "Ministra installs on Linux servers only."
case "$(uname -m)" in
    x86_64|amd64) ;;
    *) fail "Ministra needs an x86-64 server; this one is $(uname -m)." ;;
esac
[ "$(id -u)" = 0 ] || fail "Run as root: sudo sh $0"
[ -z "$version" ] || valid_version "$version" || fail "Not a version: $version"
case "$dir" in
    /*) ;;
    *) fail "--dir needs an absolute path: $dir" ;;
esac
case "$dir" in
    *[[:space:]]*) fail "--dir must not contain spaces: $dir" ;;
esac

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

mkdir -p "$dir/config" "$dir/mysql_backups"
chmod 700 "$dir"

# compose.yaml belongs to the installer and is replaced on every run
cat > "$dir/compose.yaml" <<'MINISTRA_COMPOSE_EOF'
@@MINISTRA_COMPOSE_YAML@@
MINISTRA_COMPOSE_EOF

if [ -f "$dir/.env" ]; then
    fresh=false
    previous=$(get_env MINISTRA_VERSION)
    say "Updating Ministra in $dir${previous:+ from $previous} (settings in .env are kept)"
else
    # A database left by an earlier installation keeps that installation's passwords: new
    # random ones would lock the portal out of it
    volume="${COMPOSE_PROJECT_NAME:-ministra}_mysql_data"
    if docker volume inspect "$volume" >/dev/null 2>&1; then
        rm -f "$dir/compose.yaml"
        fail "This server has a Ministra database from an earlier installation (Docker volume $volume),
but no $dir/.env with its passwords. Put that installation's .env back into $dir and run this
again, or delete the old database for good: docker volume rm $volume"
    fi

    fresh=true
    previous=
    say "Installing Ministra into $dir"

    cat > "$dir/.env" <<'MINISTRA_ENV_EOF'
@@MINISTRA_ENV_EXAMPLE@@
MINISTRA_ENV_EOF
    chmod 600 "$dir/.env"
    set_env MYSQL_PASSWORD "$(random)"
    set_env MYSQL_ROOT_PASSWORD "$(random)"
    set_env MINISTRA_API_LOGIN mintrix
    set_env MINISTRA_API_PASSWORD "$(random)"
fi

# ---------------------------------------------------------------- Mintrix

# Asks Mintrix at URL $1, with API key $2, for the download: sets registry, user, token,
# image and answer_version when it is allowed, says why not otherwise
mintrix_login() {
    answer=$(mktemp)
    url="${1%/}/api/ministra/install"
    body=$(printf '{"installer":"%s","current":"%s"}' "$INSTALLER_VERSION" "$previous")
    status=
    if command -v curl >/dev/null 2>&1; then
        # The key goes in through stdin, so it does not show in the process list
        status=$(printf 'header = "Authorization: Bearer %s"\n' "$2" \
            | curl -sS --max-time 60 -K - -H 'Content-Type: application/json' -H 'Accept: application/json' \
                --data "$body" -o "$answer" -w '%{http_code}' "$url") || status=
    else
        # GNU wget keeps an error's body only with --content-on-error, which BusyBox's lacks;
        # both print the status line with -S
        keep=
        wget --help 2>&1 | grep -q content-on-error && keep=--content-on-error
        headers=$(mktemp)
        wget -S $keep -T 60 -O "$answer" --header "Authorization: Bearer $2" \
            --header 'Content-Type: application/json' --header 'Accept: application/json' \
            --post-data "$body" "$url" 2>"$headers" || true
        status=$(grep -Eo 'HTTP/[0-9.]+ [0-9]{3}' "$headers" | tail -n 1 | awk '{print $2}')
        rm -f "$headers"
    fi
    registry=$(json_field registry "$answer")
    user=$(json_field user "$answer")
    token=$(json_field token "$answer")
    image=$(json_field image "$answer")
    answer_version=$(json_field version "$answer")
    error=$(json_field error "$answer")
    [ -s "$answer" ] || [ -n "$status" ] || status=000
    rm -f "$answer"

    [ -n "$registry" ] && [ -n "$user" ] && [ -n "$token" ] && return 0
    if [ -z "$error" ]; then
        case "$status" in
            401) error="the API key is not accepted: copy it from Mintrix > Settings > Ministra > Inbound API Key" ;;
            404) error="this Mintrix cannot install Ministra yet: update it first (mintrix-update)" ;;
            429) error="too many attempts from this server; wait a minute and try again" ;;
            000) error="Mintrix could not be reached at $1" ;;
            *) error="Mintrix could not answer${status:+ (HTTP $status)}; try again later" ;;
        esac
    fi
    echo "Not allowed by Mintrix: $error"
    return 1
}

# Both asked on every run, with the saved ones (or --mintrix and --api-key) as defaults,
# and checked by Mintrix before anything is downloaded. Only an accepted pair is saved.
say "Asking Mintrix for the download"
[ -n "$mintrix_url" ] || mintrix_url=$(get_env MINTRIX_SERVER_URL)
[ -n "$api_key" ] || api_key=$(get_env MINTRIX_API_KEY)
while :; do
    if interactive; then
        ask mintrix_url "Address of your Mintrix (e.g. https://panel.example.com)" "$mintrix_url"
        ask api_key "Its Inbound API Key (Mintrix > Settings > Ministra)" "$api_key"
    fi
    mintrix_url=${mintrix_url%/}
    case "$mintrix_url" in
        http://?*|https://?*) ;;
        *)
            interactive || fail "Ministra needs the address of your Mintrix: run again with --mintrix URL."
            echo "Enter the address users open Mintrix at, starting with https:// or http://."
            continue
            ;;
    esac
    if ! printf '%s' "$api_key" | grep -Eq '^[A-Za-z0-9_-]+$'; then
        interactive || fail "Ministra needs Mintrix's Inbound API Key: run again with --api-key KEY."
        echo "Copy the key from Mintrix > Settings > Ministra > Inbound API Key."
        continue
    fi
    mintrix_login "$mintrix_url" "$api_key" && break
    interactive || fail "Check the address and the key in Mintrix, then run this again."
done
set_env MINTRIX_SERVER_URL "$mintrix_url"
set_env MINTRIX_API_KEY "$api_key"
[ -z "$image" ] || set_env MINISTRA_IMAGE "$image"
[ -n "$version" ] || version=$answer_version
valid_version "$version" || fail "Mintrix did not name a Ministra version to install; run again with --version VERSION."
echo "Mintrix allows Ministra $version."

# Migrations only go forward: an older version would run on a database already changed
# by the newer one
if [ -n "$previous" ] && valid_version "$previous" && version_older "$version" "$previous" && [ "$force" = false ]; then
    fail "Ministra $version is older than the installed $previous, and going back does not undo
the database changes of $previous. To go back anyway, run again with --force (and restore the
backup taken before $previous from $dir/mysql_backups/ if the portal does not start)."
fi

# ---------------------------------------------------------------- port

# A new installation asks; an existing one keeps its port unless --port is given
if [ "$fresh" = true ] && [ -z "$port" ]; then
    port=80
    port_in_use 80 && { echo "Port 80 is in use on this server (Mintrix or another web server?)."; port=8080; }
    ask port "Port the portal listens on" "$port"
fi
if [ -n "$port" ]; then
    case "$port" in
        *[!0-9]*|'') fail "Not a port: $port" ;;
    esac
    { [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || fail "Not a port: $port"
    # Free, unless this installation's running portal already listens there
    current=$(get_env MINISTRA_HTTP_PORT)
    if port_in_use "$port" && ! { [ "$port" = "${current:-80}" ] \
        && compose ps --status running --services 2>/dev/null | grep -qx ministra; }; then
        fail "Port $port is in use on this server: stop what listens there, or choose another port."
    fi
    set_env MINISTRA_HTTP_PORT "$port"
fi
echo "The portal listens on port $(get_env MINISTRA_HTTP_PORT)."

# ---------------------------------------------------------------- Mintrix on this server

# When Mintrix runs here too, the portal also joins its network, so Mintrix can reach it as
# http://ministra:88 without going through the server's address
if docker network inspect mintrix_default >/dev/null 2>&1; then
    cat > "$dir/compose.mintrix.yaml" <<'EOF'
# Written by ministra-install.sh because Mintrix runs on this server: the portal joins
# Mintrix's network, where Mintrix reaches it as http://ministra:88
services:
  ministra:
    networks: [default, mintrix]
networks:
  mintrix:
    external: true
    name: mintrix_default
EOF
    same_server=true
else
    rm -f "$dir/compose.mintrix.yaml"
    same_server=false
fi

# ---------------------------------------------------------------- images

say "Downloading Ministra $version"
# Pulled before anything changes: a wrong version stops here.
# MINISTRA_SKIP_PULL=1 is only for testing images loaded on this machine.
if [ "${MINISTRA_SKIP_PULL:-}" = 1 ]; then
    echo "Skipped (MINISTRA_SKIP_PULL=1)"
else
    # The login lives in a Docker config of its own, removed after the pull: the token
    # is never kept on this server
    DOCKER_CONFIG=$(mktemp -d)
    export DOCKER_CONFIG
    trap 'rm -rf "$DOCKER_CONFIG"' EXIT
    printf '%s' "$token" | docker login "$registry" -u "$user" --password-stdin >"$DOCKER_CONFIG/login.log" 2>&1 \
        || fail "$registry refused the login Mintrix gave: $(tail -n 1 "$DOCKER_CONFIG/login.log")"
    MINISTRA_VERSION="$version" compose pull --quiet ministra mysql memcached \
        || fail "Could not download Ministra $version."
    rm -rf "$DOCKER_CONFIG"
    unset DOCKER_CONFIG
    trap - EXIT
fi
token=

if compose ps --status running --services 2>/dev/null | grep -qx mysql; then
    backup="mysql_backups/$(date +%Y%m%d-%H%M%S)-before-$version.sql"
    say "Backing up the database to $dir/$backup.gz"
    # Dumped to a file first: a failed dump stops the update before anything changes
    # shellcheck disable=SC2016  # expanded inside the MySQL container
    if ! compose exec -T mysql sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers "$MYSQL_DATABASE"' \
        > "$dir/$backup" 2>"$dir/$backup.log"; then
        rm -f "$dir/$backup"
        fail "The database backup failed, so nothing was changed: $(grep -v -i 'using a password' "$dir/$backup.log" | tail -n 1)"
    fi
    rm -f "$dir/$backup.log"
    gzip "$dir/$backup"
fi

set_env MINISTRA_VERSION "$version"

if [ "$fresh" = true ]; then
    say "Starting Ministra (the first start creates the database, which takes a few minutes)"
else
    say "Starting Ministra (database changes of a new version can take a few minutes)"
fi
compose up -d --remove-orphans --wait --wait-timeout 900 \
    || fail "Ministra did not become ready. See: cd $dir && docker compose logs --tail=100 ministra"

# ---------------------------------------------------------------- ministra-update

cat > /usr/local/bin/ministra-update <<EOF
#!/bin/sh
# Updates Ministra in $dir to the version your Mintrix names: ministra-update
# or to a given version:                                       ministra-update --version 1.2.3
set -eu
tmp=\$(mktemp)
trap 'rm -f "\$tmp"' EXIT
url=https://github.com/$REPO/releases/latest/download/ministra-install.sh
if command -v curl >/dev/null 2>&1; then curl -fsSL "\$url" -o "\$tmp"; else wget -qO "\$tmp" "\$url"; fi
sh "\$tmp" --dir "$dir" "\$@"
EOF
chmod 755 /usr/local/bin/ministra-update

# ---------------------------------------------------------------- done

http_port=$(get_env MINISTRA_HTTP_PORT)
address=$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)
portal="http://${address:-<this server>}"
[ "$http_port" = 80 ] || portal="$portal:$http_port"
portal="$portal/stalker_portal"
if [ "$same_server" = true ]; then
    mintrix_side="http://ministra:88/stalker_portal   (Mintrix runs on this server)"
else
    mintrix_side="$portal"
fi

if [ "$fresh" = true ]; then
    cat <<EOF

Ministra $version is installed.

  Portal:    $portal/c/        (for set-top boxes)
  Admin:     $portal/server/adm/
  Settings:  $dir/.env   (after a change, run: ministra-update --version $version)
  Update:    ministra-update

In Mintrix > Settings > Ministra, enter:
  Address:   $mintrix_side
  API login: $(get_env MINISTRA_API_LOGIN)
  Password:  $(get_env MINISTRA_API_PASSWORD)

Change notifications go to $mintrix_url.
EOF
else
    echo
    echo "Ministra $version is running${previous:+ (was $previous)}."
fi
