#!/bin/bash
# Copy the local repository repo/ (the result of build.sh) to
# /srv/proxmox-devuan-repo on the install machine and give it to _apt;
# optionally upgrade the machine from it (see openrc-devuan.md, "Installing"
# and "Updating after a rebuild").
#
# Usage: [REMOTE_MACHINE=root@pve2] update-repo.sh [--rsync] [--upgrade]
#   --rsync    copy with rsync --delete (mirrors repo/, removing debs no longer
#              in it; needs rsync on both machines), by default scp
#   --upgrade  run apt update && apt full-upgrade on the machine afterwards
# Run from the directory containing repo/.

set -euo pipefail

REMOTE_MACHINE=${REMOTE_MACHINE:-root@pve2}
DEST=/srv/proxmox-devuan-repo

info() { printf '\n=== %s\n' "$*"; }

RSYNC=0 UPGRADE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --rsync) RSYNC=1 ;;
        --upgrade) UPGRADE=1 ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "unknown option '$1', see --help" >&2; exit 2 ;;
    esac
    shift
done

[ -d repo ] || { echo "repo/ not found, run from the build directory" >&2; exit 1; }

info "Creating $DEST on $REMOTE_MACHINE"
ssh "$REMOTE_MACHINE" "mkdir -p $DEST"
if [ "$RSYNC" = 1 ]; then
    info "Copying repo/ to $REMOTE_MACHINE:$DEST with rsync --delete"
    rsync -a --delete --info=stats1 repo/ "$REMOTE_MACHINE:$DEST/"
else
    info "Copying repo/ to $REMOTE_MACHINE:$DEST with scp"
    scp -r repo/* "$REMOTE_MACHINE:$DEST/"
fi
info "Giving $DEST to _apt on $REMOTE_MACHINE"
ssh "$REMOTE_MACHINE" "chown -R _apt:root $DEST"

if [ "$UPGRADE" = 1 ]; then
    info "Upgrading $REMOTE_MACHINE: apt update && apt full-upgrade"
    ssh -t "$REMOTE_MACHINE" 'apt update && apt full-upgrade'
else
    info "Done; to upgrade, run apt update && apt full-upgrade on $REMOTE_MACHINE (or use --upgrade)"
fi
