#!/bin/bash
# Incremental builds: decide which build.sh steps need running, and record what
# was built, in the manifest that's published with the repository
# (repo/SOURCES). Used by the GitHub Actions workflow
# (.github/workflows/build-repo.yml), also usable by hand.
#
# Usage:
#   select-steps.sh select <what> [<manifest>]
#     <what>: 'auto'  the steps whose source repositories' commits differ from
#                     the manifest's, that it doesn't list, or whose recorded
#                     version isn't in the repository (repo/Packages), plus
#                     proxmox-default-kernel (Proxmox's current kernel, only
#                     downloaded)
#             'all'   all steps
#             or step names, comma- or space-separated
#     Prints the steps comma-separated in build order (for build.sh --only),
#     nothing if there's nothing to build; warnings on stderr.
#   select-steps.sh record <manifest> <step>...
#     Write the given (built) steps' versions and commits into the manifest,
#     keeping the other steps' lines.
#
# Manifest, one line per step, in build order:
#   <step> <version> [<repository>=<commit>...]
# Run from the directory with the repositories and build.sh (as build.sh).

set -euo pipefail

BASE=$(pwd)
BUILD=$(dirname "$(readlink -f "$0")")/build.sh
R=$BASE/repo

mapfile -t STEPS < <("$BUILD" --list)

warn() {
    # a GitHub Actions annotation in the workflow (read from stderr too, stdout
    # is the result), plain otherwise
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        echo "::warning::$*" >&2
    else
        echo "WARNING: $*" >&2
    fi
}
die() { echo "ERROR: $*" >&2; exit 1; }

sources() { "$BUILD" --sources "$1" | sed -n 's/^repositories: *//p'; }
changelog() { "$BUILD" --sources "$1" | sed -n 's/^changelog: *//p'; }

# the version a step's packages get: its changelog's, or for the downloaded
# kernel the newest proxmox-default-kernel in repo/
step_version() { # <step>
    local cl f v best=''
    cl=$(changelog "$1")
    if [ -n "$cl" ]; then
        dpkg-parsechangelog -l "$BASE/$cl" -S Version
        return
    fi
    for f in "$R"/proxmox-default-kernel_*.deb; do
        [ -e "$f" ] || continue
        v=$(dpkg-deb -f "$f" Version)
        if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$best"; then best=$v; fi
    done
    echo "${best:--}"
}

step_commits() { # <step>
    local repo out=()
    for repo in $(sources "$1"); do
        [ -d "$BASE/$repo/.git" ] || die "$repo (for $1) not cloned, run prepare-build.sh"
        out+=("$repo=$(git -C "$BASE/$repo" rev-parse HEAD)")
    done
    echo "${out[*]}"
}

manifest_line() { # <manifest> <step>
    [ -f "$1" ] || return 0
    awk -v s="$2" '$1 == s' "$1"
}

select_steps() { # <what> [<manifest>]
    local what=$1 manifest=${2:-$R/SOURCES} step selected=() line old_version repo commit old
    case "$what" in
        all) selected=("${STEPS[@]}") ;;
        auto)
            for step in "${STEPS[@]}"; do
                if [ -z "$(sources "$step")" ]; then
                    selected+=("$step")   # proxmox-default-kernel: always fetched
                    continue
                fi
                line=$(manifest_line "$manifest" "$step")
                if [ -z "$line" ]; then
                    echo "$step: not in the manifest" >&2
                    selected+=("$step")
                    continue
                fi
                old_version=$(awk '{print $2}' <<<"$line")
                # the manifest is only right with its packages: e.g. a
                # repository packed from a machine with older builds
                if ! grep -qxF "Version: $old_version" "$R/Packages" 2>/dev/null; then
                    echo "$step: $old_version not in the repository" >&2
                    selected+=("$step")
                    continue
                fi
                for repo in $(sources "$step"); do
                    commit=$(git -C "$BASE/$repo" rev-parse HEAD)
                    old=$(tr ' ' '\n' <<<"$line" | sed -n "s/^$repo=//p")
                    if [ "$commit" != "$old" ]; then
                        echo "$step: $repo changed (${old:0:10} -> ${commit:0:10})" >&2
                        selected+=("$step")
                        if [ "$(step_version "$step")" = "$old_version" ]; then
                            warn "$step: sources changed, but the version is still $old_version (bump the changelog: apt won't upgrade to a rebuild with the same version)"
                        fi
                        break
                    fi
                done
            done ;;
        *)
            local s
            for s in ${what//,/ }; do
                printf '%s\n' "${STEPS[@]}" | grep -qxF "$s" || die "unknown step '$s', see build.sh --list"
            done
            # in build order
            for step in "${STEPS[@]}"; do
                for s in ${what//,/ }; do
                    [ "$s" = "$step" ] && selected+=("$step")
                done
            done ;;
    esac
    local IFS=,
    echo "${selected[*]}"
}

record_steps() { # <manifest> <step>...
    local manifest=$1 step tmp; shift
    tmp=$(mktemp)
    for step in "${STEPS[@]}"; do
        if printf '%s\n' "$@" | grep -qxF "$step"; then
            echo "$step $(step_version "$step") $(step_commits "$step")" | sed 's/ *$//'
        else
            manifest_line "$manifest" "$step"
        fi
    done >"$tmp"
    mv "$tmp" "$manifest"
}

case "${1:-}" in
    select) shift; [ $# -ge 1 ] || die "usage: $0 select <what> [<manifest>]"; select_steps "$@" ;;
    record) shift; [ $# -ge 1 ] || die "usage: $0 record <manifest> <step>..."; record_steps "$@" ;;
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0" ;;
    *) die "usage: $0 select|record ..., see --help" ;;
esac
