#!/bin/bash
# List the systemd-related changes in the upstream commits the last build
# lacks: for each proxmox/* tag (see upstream-tags.sh) that isn't in a clone's
# HEAD, scan the commits merge-base(HEAD, tag)..tag for
#
#  - added or removed lines matching the patterns of systemd-usage-analysis.md
#    ("How the scan was done"): systemctl, the journal, scopes, sd_notify,
#    D-Bus, tmpfiles/sysusers, other systemd tools, unit file keys
#  - changed files that are units (.service, .socket, .timer, .target, .mount,
#    .path, .slice, .link, .network, .netdev), tmpfiles/sysusers files, or have
#    systemd in their path
#
# debian/changelog and translations (po/) are left out. The hits need checking
# by hand; known false positives are .scope in JavaScript, systemd inside
# guests (pve-container's PVE::LXC::Setup), and systemd-boot (the boot loader).
#
# Usage: upstream-systemd-scan.sh [--lines <n>] [<repository>...]
#   --lines <n>    show at most <n> matching lines per commit (default: 12)
#   <repository>   only these clones (default: all of prepare-build.sh's)
# Run from the build directory (the one with the clones), after
# upstream-tags.sh has fetched upstream and created the tags.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

MAX_LINES=12 ONLY=()
while [ $# -gt 0 ]; do
    case "$1" in
        --lines) MAX_LINES=${2:?--lines needs a number}; shift ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*) echo "unknown option '$1', see --help" >&2; exit 2 ;;
        *) ONLY+=("$1") ;;
    esac
    shift
done

# The repository lists, from prepare-build.sh, so they're kept in one place
eval "$(sed -n '/^BUILD_REPOS=(/,/^)/p; /^SOURCE_REPOS=(/p' "$HERE/prepare-build.sh")"
REPOS=("${BUILD_REPOS[@]}" "${SOURCE_REPOS[@]}")
[ ${#ONLY[@]} -eq 0 ] || REPOS=("${ONLY[@]}")

# Changed lines (systemd-usage-analysis.md's patterns, plus unit file keys)
LINE_PATTERN='systemctl|journalctl|mini-journalreader|sd_journal|tracing-journald|systemd'
LINE_PATTERN+='|StartTransientUnit|\.scope\b|sd_notify|sd_listen_fds|NOTIFY_SOCKET|sd_pid_notify'
LINE_PATTERN+='|org\.freedesktop|Net::DBus|tmpfiles|sysusers|loginctl|hostnamectl|timedatectl'
LINE_PATTERN+='|systemd-escape|detect-virt|udevadm|networkctl|deb-systemd|dh_installsystemd'
LINE_PATTERN+='|\.(service|socket|timer|target|mount|path|slice)\b|WantedBy|ExecStart|Type=notify'
# Changed files
FILE_PATTERN='\.(service|socket|timer|target|mount|path|slice|link|network|netdev)$|tmpfiles|sysusers|systemd'

total=0 hits=0
for r in "${REPOS[@]}"; do
    if [ ! -d "$r/.git" ]; then echo "WARNING: $r: no clone here, skipped" >&2; continue; fi
    for tag in $(git -C "$r" tag -l 'proxmox/*'); do
        git -C "$r" merge-base --is-ancestor "$tag" HEAD && continue
        base=$(git -C "$r" merge-base HEAD "$tag")
        count=$(git -C "$r" rev-list --count "$base..$tag")
        total=$((total + count))
        printf '\n=== %s %s: %d commits (%s..%s)\n' "$r" "$tag" "$count" \
            "$(git -C "$r" rev-parse --short "$base")" "$(git -C "$r" rev-parse --short "$tag")"
        found=0
        for c in $(git -C "$r" rev-list --reverse "$base..$tag"); do
            files=$(git -C "$r" show --format= --name-only "$c" | grep -E "$FILE_PATTERN" || true)
            lines=$(git -C "$r" show --format= --unified=0 "$c" -- . \
                    ':(exclude)debian/changelog' ':(exclude)*/debian/changelog' \
                    ':(exclude)po' ':(exclude)*.po' \
                | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' | grep -iE "$LINE_PATTERN" \
                | head -n "$MAX_LINES" || true)
            [ -n "$files$lines" ] || continue
            found=1 hits=$((hits + 1))
            echo "--- $(git -C "$r" log -1 --format='%h %ad %s' --date=short "$c")"
            [ -z "$files" ] || echo "$files" | sed 's/^/    file: /'
            [ -z "$lines" ] || echo "$lines" | cut -c1-200 | sed 's/^/    /'
        done
        [ "$found" = 1 ] || echo "(no systemd-related changes)"
    done
done

printf '\n%d of %d commits with systemd-related changes\n' "$hits" "$total"
