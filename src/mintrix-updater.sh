#!/bin/sh
# Runs an update asked for in Mintrix (Settings > System Update). install.sh writes this to
# /usr/local/bin/mintrix-updater; systemd starts it (mintrix-updater.service, as root) when
# mintrix-updater.path sees $MINTRIX_DIR/runtime/update/request.json.
#
# The app writes request.json ({"id", "version", ...}) and reads status.json, which this
# script keeps up to date: state running | done | failed (nothing changed) | rolled_back
# (the previous version and its database are back), and the step (download, backup, start,
# license, rollback). The request is only trusted for a version: it is checked again here.
set -u

dir="${MINTRIX_DIR:-/opt/mintrix}"
repo="${MINTRIX_REPO:-newiqllc/mintrix}"
up="$dir/runtime/update"
req="$up/request.json"
log="$up/update.log"
keep="$up/rollback"

[ -f "$req" ] || exit 0

# Taken first, so the path unit does not start this again for the same request
taken="$up/.taken.json"
mv "$req" "$taken" || exit 0
id=$(sed -n 's/.*"id": *"\([0-9a-fA-F-]\{36\}\)".*/\1/p' "$taken")
version=$(sed -n 's/.*"version": *"\([0-9][0-9A-Za-z.-]*\)".*/\1/p' "$taken")
rm -f "$taken"

from=$(sed -n 's/^MINTRIX_VERSION=//p' "$dir/.env" | tail -n 1)
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
step=download
: > "$log"

# A JSON string's content: control characters dropped, \ and " escaped, lines joined by \n
json() {
    printf '%s' "$1" | tr -d '\000-\010\013-\037' | sed 's/\\/\\\\/g; s/"/\\"/g' \
        | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

# status STATE [MESSAGE]: written whole, then renamed, so the app never reads half a file
status() {
    finished=
    [ "$1" = running ] || finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    tail_log=$(tail -n 60 "$log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
    cat > "$up/.status.json" <<EOF
{
  "id": "$id",
  "version": "$(json "$version")",
  "from": "$(json "$from")",
  "state": "$1",
  "step": "$step",
  "message": "$(json "${2:-}")",
  "log": "$(json "$tail_log")",
  "started_at": "$started",
  "finished_at": "$finished"
}
EOF
    chmod 644 "$up/.status.json"
    mv "$up/.status.json" "$up/status.json"
}

if [ -z "$id" ] || ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$'; then
    status failed "Not a valid update request."
    exit 1
fi
if [ "$version" = "$from" ] || [ "$(printf '%s\n%s\n' "$from" "$version" | sort -V | tail -n 1)" != "$version" ]; then
    status failed "Mintrix $version is not newer than $from."
    exit 1
fi

status running

# What a rollback needs: this version's compose.yaml and .env (the new install.sh replaces compose.yaml)
rm -rf "$keep" && mkdir -p "$keep"
cp "$dir/compose.yaml" "$dir/.env" "$keep/"
[ ! -f "$dir/compose.override.yaml" ] || cp "$dir/compose.override.yaml" "$keep/"

# The installer of the version being installed, not the newest one
installer=$(mktemp)
url="https://github.com/$repo/releases/download/v$version/install.sh"
if ! { curl -fsSL "$url" -o "$installer" || wget -qO "$installer" "$url"; } >>"$log" 2>&1; then
    rm -f "$installer"
    status failed "Could not download the installer for $version: $url"
    exit 1
fi

# install.sh writes its current step to this file (download, backup, start, license)
MINTRIX_STEP_FILE="$up/.step"
export MINTRIX_STEP_FILE
rm -f "$MINTRIX_STEP_FILE"
sh "$installer" --dir "$dir" --version "$version" --yes >>"$log" 2>&1 &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    current=$(cat "$MINTRIX_STEP_FILE" 2>/dev/null || true)
    [ -z "$current" ] || step=$current
    status running
done
wait "$pid"
code=$?
current=$(cat "$MINTRIX_STEP_FILE" 2>/dev/null || true)
[ -z "$current" ] || step=$current
rm -f "$installer" "$MINTRIX_STEP_FILE"

if [ "$code" -eq 0 ]; then
    rm -rf "$keep"
    status "done"
    exit 0
fi

# Before the start nothing has changed: install.sh pulls and backs up first
case "$step" in
    download|backup)
        status failed "$(grep -v '^\s*$' "$log" | tail -n 1 | sed 's/\x1b\[[0-9;]*m//g')"
        exit 1 ;;
esac

# ---------------------------------------------------------------- rollback

failed_at=$step
step=rollback
status running
echo "==> Rolling back to Mintrix $from" >>"$log"

compose() {
    if [ -f "$dir/compose.override.yaml" ]; then
        docker compose --project-directory "$dir" -f "$dir/compose.yaml" -f "$dir/compose.override.yaml" "$@"
    else
        docker compose --project-directory "$dir" -f "$dir/compose.yaml" "$@"
    fi
}

# Backup names start with the date, so the last in name order is the newest
backup=$(find "$dir/mysql_backups" -maxdepth 1 -name "*-before-$version.sql.gz" 2>/dev/null | sort | tail -n 1)
cp "$keep/compose.yaml" "$keep/.env" "$dir/"
[ ! -f "$keep/compose.override.yaml" ] || cp "$keep/compose.override.yaml" "$dir/"

(
    set -e
    compose stop nginx app queue scheduler
    if [ -n "$backup" ]; then
        # The database as it was before the new version changed it
        # shellcheck disable=SC2016  # expanded inside the MySQL container
        compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\`"'
        # shellcheck disable=SC2016
        gunzip -c "$backup" | compose exec -T mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'
    fi
    compose up -d --remove-orphans --wait --wait-timeout 600
) >>"$log" 2>&1
rolled=$?

if [ "$rolled" -eq 0 ]; then
    status rolled_back "The update stopped at \"$failed_at\"; Mintrix $from and its database were restored."
else
    status failed "The update stopped at \"$failed_at\" and the rollback did not finish. See $log (backup: ${backup:-none})."
fi
exit 1
