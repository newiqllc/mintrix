#!/bin/sh
# Runs Ministra updates asked for in Mintrix (Settings > Ministra > Update). ministra-install.sh
# writes this to /usr/local/bin/ministra-updater; a systemd timer (ministra-updater.timer)
# starts it every minute, as root.
#
# Ministra often runs on another server than Mintrix, so this asks Mintrix, with the address
# and Inbound API Key in .env: it checks in (saying which Ministra runs here), and when an
# update is waiting it runs ministra-update for that version (database backup first) and
# reports its progress. When the new version does not start, the previous one and its
# database are put back. Mintrix only names a version: it is checked here, and never older.
set -u

dir="${MINISTRA_DIR:-/opt/ministra}"
installer_version="${MINISTRA_INSTALLER_VERSION:-}"
up="$dir/update"
log="$up/update.log"
keep="$up/rollback"

[ -f "$dir/.env" ] || exit 0
get_env() { sed -n "s/^$1=//p" "$dir/.env" | tail -n 1; }

mintrix=$(get_env MINTRIX_SERVER_URL)
key=$(get_env MINTRIX_API_KEY)
from=$(get_env MINISTRA_VERSION)
[ -n "$mintrix" ] && [ -n "$key" ] || exit 0
url="${mintrix%/}/api/ministra/update"

valid_version() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$'; }

# http GET|POST URL [BODY] > answer; the key goes in through stdin or a header file, so it
# does not show in the process list
http() {
    if command -v curl >/dev/null 2>&1; then
        if [ "$1" = POST ]; then
            printf 'header = "Authorization: Bearer %s"\n' "$key" \
                | curl -fsS --max-time 30 -K - -H 'Content-Type: application/json' -H 'Accept: application/json' --data "$3" "$2"
        else
            printf 'header = "Authorization: Bearer %s"\n' "$key" \
                | curl -fsS --max-time 30 -K - -H 'Accept: application/json' "$2"
        fi
    else
        headers=$(mktemp)
        printf 'header = Authorization: Bearer %s\nheader = Accept: application/json\nheader = Content-Type: application/json\n' "$key" > "$headers"
        if [ "$1" = POST ]; then
            WGETRC="$headers" wget -qO- -T 30 --post-data "$3" "$2"
        else
            WGETRC="$headers" wget -qO- -T 30 "$2"
        fi
        code=$?
        rm -f "$headers"
        return $code
    fi
}

# A JSON string's content: control characters dropped, \ and " escaped, lines joined by \n
json() {
    printf '%s' "$1" | tr -d '\000-\010\013-\037' | sed 's/\\/\\\\/g; s/"/\\"/g' \
        | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

# ---------------------------------------------------------------- check in

answer=$(http GET "$url?current=$from&installer=$installer_version") || exit 0
id=$(printf '%s' "$answer" | sed -n 's/.*"id": *"\([0-9a-fA-F-]\{36\}\)".*/\1/p')
version=$(printf '%s' "$answer" | sed -n 's/.*"version": *"\([0-9][0-9A-Za-z.-]*\)".*/\1/p')
[ -n "$id" ] || exit 0

mkdir -p "$up"
: > "$log"
step=download

# report STATE [MESSAGE]: the step and the end of the log go with it
report() {
    tail_log=$(tail -n 60 "$log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
    body=$(printf '{"id":"%s","state":"%s","step":"%s","message":"%s","log":"%s"}' \
        "$id" "$1" "$step" "$(json "${2:-}")" "$(json "$tail_log")")
    http POST "$url" "$body" >/dev/null 2>&1 || true
}

if ! valid_version "$version"; then
    report failed "Not a valid Ministra version: $version"
    exit 1
fi
if [ "$version" = "$from" ] || { valid_version "$from" && [ "$(printf '%s\n%s\n' "$from" "$version" | sort -V | tail -n 1)" != "$version" ]; }; then
    report failed "Ministra $version is not newer than the installed $from."
    exit 1
fi
if ! command -v ministra-update >/dev/null 2>&1; then
    report failed "ministra-update is missing on this server; run ministra-install.sh again."
    exit 1
fi

report running
echo "==> Updating Ministra $from to $version" >>"$log"

# What a rollback needs: this version's compose files and .env (the installer replaces them)
rm -rf "$keep" && mkdir -p "$keep"
cp "$dir/.env" "$dir"/compose*.yaml "$keep/" 2>/dev/null

# ministra-install.sh writes its current step to this file (download, backup, start)
MINISTRA_STEP_FILE="$up/.step"
export MINISTRA_STEP_FILE
rm -f "$MINISTRA_STEP_FILE"
ministra-update --version "$version" --yes >>"$log" 2>&1 &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    current=$(cat "$MINISTRA_STEP_FILE" 2>/dev/null || true)
    [ -z "$current" ] || step=$current
    report running
done
wait "$pid"
code=$?
current=$(cat "$MINISTRA_STEP_FILE" 2>/dev/null || true)
[ -z "$current" ] || step=$current
rm -f "$MINISTRA_STEP_FILE"

if [ "$code" -eq 0 ]; then
    rm -rf "$keep"
    report "done"
    exit 0
fi

# Before the start nothing has changed: the installer downloads and backs up first
case "$step" in
    download|backup)
        report failed "$(grep -v '^\s*$' "$log" | tail -n 1 | sed 's/\x1b\[[0-9;]*m//g')"
        exit 1 ;;
esac

# ---------------------------------------------------------------- rollback

failed_at=$step
step=rollback
report running
echo "==> Rolling back to Ministra $from" >>"$log"

compose() {
    files="-f $dir/compose.yaml"
    [ ! -f "$dir/compose.mintrix.yaml" ] || files="$files -f $dir/compose.mintrix.yaml"
    [ ! -f "$dir/compose.override.yaml" ] || files="$files -f $dir/compose.override.yaml"
    # shellcheck disable=SC2086  # $dir has no spaces (ministra-install.sh checks)
    docker compose --project-directory "$dir" $files "$@"
}

# Backup names start with the date, so the last in name order is the newest
backup=$(find "$dir/mysql_backups" -maxdepth 1 -name "*-before-$version.sql.gz" 2>/dev/null | sort | tail -n 1)
cp "$keep"/.env "$keep"/compose*.yaml "$dir/"

(
    set -e
    compose stop ministra cron
    if [ -n "$backup" ]; then
        # The database as it was before the new version changed it
        # shellcheck disable=SC2016  # expanded inside the MySQL container
        compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\`"'
        # shellcheck disable=SC2016
        gunzip -c "$backup" | compose exec -T mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'
    fi
    compose up -d --remove-orphans --wait --wait-timeout 900
) >>"$log" 2>&1
rolled=$?

if [ "$rolled" -eq 0 ]; then
    rm -rf "$keep"
    report rolled_back "The update stopped at \"$failed_at\"; Ministra $from and its database were restored."
else
    report failed "The update stopped at \"$failed_at\" and the rollback did not finish. See $log on the Ministra server (backup: ${backup:-none})."
fi
exit 1
