#!/bin/bash
# Prepare the local repository repo/ for publishing (the GitHub Actions
# workflow .github/workflows/build-repo.yml, also usable by hand).
#
# Usage: package-repo.sh [--prune] [--sign <key>] [--tarball <file>] [<repo dir>]
#   --prune           remove all but the newest version of each package, and
#                     regenerate the index (Packages)
#   --sign <key>      write Release (the indexes' checksums) and sign it with
#                     the given key (ID or fingerprint, e.g. a signing subkey's
#                     with a trailing '!') as InRelease and Release.gpg, which
#                     apt verifies; the passphrase, if any, from GPG_PASSPHRASE
#   --tarball <file>  pack the repository (packages, indexes, Release files,
#                     SOURCES; not the build scripts) into <file> (.tar.gz),
#                     with --sign also signed, as <file>.asc
# <repo dir> defaults to ./repo. Needs apt-ftparchive (apt-utils) and gpg.

set -euo pipefail

PRUNE=0 KEY='' TARBALL='' DIR=repo
while [ $# -gt 0 ]; do
    case "$1" in
        --prune) PRUNE=1 ;;
        --sign) KEY=$2; shift ;;
        --tarball) TARBALL=$2; shift ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*) echo "unknown option '$1', see --help" >&2; exit 2 ;;
        *) DIR=$1 ;;
    esac
    shift
done

die() { echo "ERROR: $*" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd) || die "no repository directory $DIR"

# as repo/update-index.sh (prepare-build.sh): only the packages directly in
# the directory
write_index() {
    (cd "$DIR" && apt-ftparchive packages . \
        | awk -v RS= -v ORS='\n\n' '$0 ~ /\nFilename: \.\/[^\/\n]+\n/' > Packages && gzip -9kf Packages)
}

prune() {
    local f p v n=0
    declare -A newest=() newest_v=()
    for f in "$DIR"/*.deb; do
        [ -e "$f" ] || continue
        p=$(dpkg-deb -f "$f" Package)
        v=$(dpkg-deb -f "$f" Version)
        if [ -z "${newest[$p]:-}" ] || dpkg --compare-versions "$v" gt "${newest_v[$p]}"; then
            newest[$p]=$f newest_v[$p]=$v
        fi
    done
    for f in "$DIR"/*.deb; do
        [ -e "$f" ] || continue
        p=$(dpkg-deb -f "$f" Package)
        if [ "${newest[$p]}" != "$f" ]; then
            echo "pruned $(basename "$f") (newest: ${newest_v[$p]})"
            rm -f "$f"; n=$((n + 1))
        fi
    done
    echo "pruned $n older package versions, ${#newest[@]} packages left"
    write_index
}

gpg_sign() { # <gpg options>...
    local pass=()
    [ -n "${GPG_PASSPHRASE:-}" ] && pass=(--pinentry-mode loopback --passphrase-fd 0)
    gpg --batch --yes --local-user "$KEY" "${pass[@]}" "$@" <<<"${GPG_PASSPHRASE:-}"
}

sign() {
    local tmp
    [ -f "$DIR/Packages" ] || die "$DIR/Packages missing"
    rm -f "$DIR/Release" "$DIR/InRelease" "$DIR/Release.gpg"
    tmp=$(mktemp)
    (cd "$DIR" && apt-ftparchive \
        -o APT::FTPArchive::Release::Origin=proxmox-devuan \
        -o APT::FTPArchive::Release::Label="Proxmox VE for Devuan" \
        -o APT::FTPArchive::Release::Codename=excalibur \
        -o APT::FTPArchive::Release::Architectures="amd64 all" \
        release .) > "$tmp"
    mv "$tmp" "$DIR/Release"
    gpg_sign --clearsign -o "$DIR/InRelease" "$DIR/Release"
    gpg_sign --armor --detach-sign -o "$DIR/Release.gpg" "$DIR/Release"
    echo "signed Release with $KEY"
}

pack() {
    mkdir -p "$(dirname "$TARBALL")"
    tar -C "$DIR" --exclude=./build-repo.sh --exclude=./update-index.sh -czf "$TARBALL" .
    echo "packed $(tar -tzf "$TARBALL" | grep -c '\.deb$') packages into $TARBALL ($(du -h "$TARBALL" | cut -f1))"
    if [ -n "$KEY" ]; then
        gpg_sign --armor --detach-sign -o "$TARBALL.asc" "$TARBALL"
        echo "signed $TARBALL.asc"
    fi
}

[ $PRUNE = 1 ] && prune
[ -n "$KEY" ] && sign
[ -n "$TARBALL" ] && pack
exit 0
