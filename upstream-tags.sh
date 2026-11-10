#!/bin/bash
# Tag Proxmox's latest released version of each package rebuilt here:
#
#  1. fetch Proxmox's repository (remote 'upstream') in each clone that
#     prepare-build.sh makes (BUILD_REPOS and SOURCE_REPOS)
#  2. look up the latest version of each source package these repositories
#     build in Proxmox's package index (trixie, pve-no-subscription)
#  3. find the upstream commit that introduced that version in the package's
#     debian/changelog (the "bump version" commit), and tag it locally as
#     proxmox/<source>/<version> (DEP-14 mangling: ':' -> '%', '~' -> '_')
#
# Prints one line per source package: the version of the current checkout
# (the last build), Proxmox's latest version, the tag, and how many upstream
# commits the checkout lacks up to the tag. Tags are only created locally,
# never pushed; an existing tag is kept (with a warning if it points elsewhere).
# Source packages that aren't in Proxmox's index (proxmox-rs' and perlmod's
# crates) are skipped.
#
# Usage: upstream-tags.sh [--no-fetch] [--dry-run] [<repository>...]
#   --no-fetch  use the upstream commits already fetched
#   --dry-run   find the commits, but don't create tags
#   <repository>  only these clones (default: all of prepare-build.sh's)
# Run from the build directory (the one with the clones).
#
# Environment:
#   PROXMOX_REPO  Proxmox's apt repository (default: http://download.proxmox.com/debian/pve)
#   DIST          distribution (default: trixie)
#   COMPONENT     component (default: pve-no-subscription)

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PROXMOX_REPO=${PROXMOX_REPO:-http://download.proxmox.com/debian/pve}
DIST=${DIST:-trixie}
COMPONENT=${COMPONENT:-pve-no-subscription}

DO_FETCH=1 DRY_RUN=0 ONLY=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-fetch) DO_FETCH=0 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*) echo "unknown option '$1', see --help" >&2; exit 2 ;;
        *) ONLY+=("$1") ;;
    esac
    shift
done

info() { printf '\n=== %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; WARNINGS+=("$*"); }
WARNINGS=()

# The repository lists, from prepare-build.sh, so they're kept in one place
eval "$(sed -n '/^BUILD_REPOS=(/,/^)/p; /^SOURCE_REPOS=(/p' "$HERE/prepare-build.sh")"
REPOS=("${BUILD_REPOS[@]}" "${SOURCE_REPOS[@]}")
[ ${#ONLY[@]} -eq 0 ] || REPOS=("${ONLY[@]}")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# DEP-14 tag name for a Debian version
tag_version() { local v=${1//:/%}; echo "${v//\~/_}"; }

# The first line of <file> at <commit> in clone <dir> (the newest changelog
# entry); head closes the pipe early, which isn't an error here
top_line() { git -C "$1" show "$2:$3" 2>/dev/null | head -1 || true; }

# The highest version of source package <name> in Proxmox's index, if any
latest_version() {
    local best='' v
    while read -r v; do
        if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$best"; then best=$v; fi
    done < <(awk -v s="$1" '$1 == s { print $2 }' "$TMP/sources")
    echo "$best"
}

info "Fetching Proxmox's package index ($DIST $COMPONENT)"
curl -fsSL "$PROXMOX_REPO/dists/$DIST/$COMPONENT/binary-amd64/Packages.gz" | gunzip > "$TMP/Packages"
# "<source> <version>" for every binary package; Source may carry its own
# version in parentheses when it differs from the binary's
awk '
    /^Package: / { pkg = $2; src = ""; srcver = "" }
    /^Source: /  { src = $2; if ($3 ~ /^\(/) { srcver = $3; gsub(/[()]/, "", srcver) } }
    /^Version: / { ver = $2 }
    /^$/ { if (pkg != "") print (src != "" ? src : pkg), (srcver != "" ? srcver : ver); pkg = "" }
    END  { if (pkg != "") print (src != "" ? src : pkg), (srcver != "" ? srcver : ver) }
' "$TMP/Packages" | sort -u > "$TMP/sources"
echo "$(wc -l < "$TMP/sources") source package versions"

if [ "$DO_FETCH" = 1 ]; then
    info "Fetching upstream in ${#REPOS[@]} repositories"
    for r in "${REPOS[@]}"; do
        if [ ! -d "$r/.git" ]; then warn "$r: no clone here, skipped"; continue; fi
        git -C "$r" fetch -q upstream && echo "$r: fetched" || warn "$r: fetch failed"
    done
fi

info "Tagging Proxmox's latest releases"
printf '%-24s %-24s %-24s %-22s %s\n' REPOSITORY SOURCE BUILT LATEST "TAG / MISSING COMMITS"
for r in "${REPOS[@]}"; do
    [ -d "$r/.git" ] || continue
    # Every debian/changelog Proxmox has, across the upstream branches
    mapfile -t changelogs < <(git -C "$r" log --remotes=upstream --format= --name-only -- \
        'debian/changelog' '*/debian/changelog' | sort -u)
    for cl in "${changelogs[@]}"; do
        src=$(top_line "$r" "$(git -C "$r" log -1 --remotes=upstream --format=%H -- "$cl")" "$cl" | awk '{print $1}')
        latest=$(latest_version "$src")
        [ -n "$latest" ] || continue
        built=$(top_line "$r" HEAD "$cl" | sed -n 's/^[^ ]* (\([^)]*\)).*/\1/p')

        # The oldest upstream commit whose changelog starts with this version
        commit=''
        for c in $(git -C "$r" log --remotes=upstream --reverse --format=%H -S"$src ($latest)" -- "$cl"); do
            case "$(top_line "$r" "$c" "$cl")" in "$src ($latest)"*) commit=$c; break ;; esac
        done
        if [ -z "$commit" ]; then
            warn "$r: no upstream commit for $src $latest in $cl"
            printf '%-24s %-24s %-24s %-22s %s\n' "$r" "$src" "${built:--}" "$latest" "(no commit found)"
            continue
        fi

        tag=proxmox/$src/$(tag_version "$latest")
        existing=$(git -C "$r" rev-parse -q --verify "refs/tags/$tag^{commit}" 2>/dev/null || true)
        if [ -n "$existing" ] && [ "$existing" != "$commit" ]; then
            warn "$r: tag $tag exists at ${existing:0:12}, not at ${commit:0:12}; kept"
        elif [ -z "$existing" ] && [ "$DRY_RUN" = 0 ]; then
            git -C "$r" tag "$tag" "$commit"
        fi

        if git -C "$r" merge-base --is-ancestor "$commit" HEAD; then
            missing="included"
        else
            missing="$(git -C "$r" rev-list --count "$(git -C "$r" merge-base HEAD "$commit")..$commit") commits"
        fi
        printf '%-24s %-24s %-24s %-22s %s\n' "$r" "$src" "${built:--}" "$latest" "$tag ${commit:0:12}, $missing"
    done
done

if [ ${#WARNINGS[@]} -gt 0 ]; then
    info "Warnings"
    printf '  %s\n' "${WARNINGS[@]}"
fi
[ "$DRY_RUN" = 0 ] || echo "(dry run: no tags created)"
