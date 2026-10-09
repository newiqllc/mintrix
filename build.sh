#!/bin/sh
# Builds the installers, with the version, the repository, the license server and the
# files they write filled in:
#   dist/install.sh            Mintrix: src/install.sh with src/compose.yaml, src/env.example,
#                              src/mintrix-updater.sh
#   dist/ministra-install.sh   Ministra: src/ministra-install.sh with src/ministra-compose.yaml,
#                              src/ministra-env.example
#
#   sh build.sh 0.1.0 [OWNER/REPO]
#   LICENSE_SERVER=https://staging.example.com sh build.sh 0.1.0    (testing only)
set -eu

version="${1:-}"
repo="${2:-${GITHUB_REPOSITORY:-newiqllc/mintrix}}"
license_server="${LICENSE_SERVER:-https://license.newiq.pl}"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$' \
    || { echo "Usage: $0 MAJOR.MINOR.PATCH[-beta.N] [OWNER/REPO]" >&2; exit 1; }

cd "$(dirname "$0")"

# The files go into quoted heredocs: their end markers must not appear in them
for f in src/compose.yaml src/env.example src/ministra-compose.yaml src/ministra-env.example src/mintrix-updater.sh; do
    ! grep -Eq '^(MINTRIX|MINISTRA)_.*_EOF$' "$f" || { echo "$f contains a heredoc end marker" >&2; exit 1; }
done

mkdir -p dist
for script in install.sh ministra-install.sh; do
    awk -v version="$version" -v repo="$repo" -v license_server="$license_server" '
        function embed(file,   line) { while ((getline line < file) > 0) print line; close(file) }
        $0 == "@@COMPOSE_YAML@@"          { embed("src/compose.yaml"); next }
        $0 == "@@ENV_EXAMPLE@@"           { embed("src/env.example");  next }
        $0 == "@@MINTRIX_UPDATER@@"       { embed("src/mintrix-updater.sh"); next }
        $0 == "@@MINISTRA_COMPOSE_YAML@@" { embed("src/ministra-compose.yaml"); next }
        $0 == "@@MINISTRA_ENV_EXAMPLE@@"  { embed("src/ministra-env.example");  next }
        { gsub(/@@VERSION@@/, version); gsub(/@@REPO@@/, repo); gsub(/@@LICENSE_SERVER@@/, license_server); print }
    ' "src/$script" > "dist/$script"

    ! grep -q '@@[A-Z_]*@@' "dist/$script" || { echo "Unfilled placeholder in dist/$script" >&2; exit 1; }
    sh -n "dist/$script"
done
echo "Built dist/install.sh and dist/ministra-install.sh ($version, $repo, $license_server)"
