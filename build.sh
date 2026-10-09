#!/bin/sh
# Builds dist/install.sh: src/install.sh with the version, the repository, the license
# server and the files it writes (src/compose.yaml, src/env.example) filled in.
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
for f in src/compose.yaml src/env.example; do
    ! grep -q '^MINTRIX_.*_EOF$' "$f" || { echo "$f contains a heredoc end marker" >&2; exit 1; }
done

mkdir -p dist
awk -v version="$version" -v repo="$repo" -v license_server="$license_server" '
    function embed(file,   line) { while ((getline line < file) > 0) print line; close(file) }
    $0 == "@@COMPOSE_YAML@@" { embed("src/compose.yaml"); next }
    $0 == "@@ENV_EXAMPLE@@"  { embed("src/env.example");  next }
    { gsub(/@@VERSION@@/, version); gsub(/@@REPO@@/, repo); gsub(/@@LICENSE_SERVER@@/, license_server); print }
' src/install.sh > dist/install.sh

! grep -q '@@[A-Z_]*@@' dist/install.sh || { echo "Unfilled placeholder in dist/install.sh" >&2; exit 1; }
sh -n dist/install.sh
echo "Built dist/install.sh ($version, $repo, $license_server)"
