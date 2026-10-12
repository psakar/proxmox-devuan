#!/bin/bash
# Build inside a Devuan excalibur container, for .github/workflows/build-repo.yml
# (docker run ... devuan/devuan:excalibur /work/ci/build-in-container.sh):
# as root, set up a build user like the build machine's (owning the workspace,
# passwordless sudo), then as that user:
#   - prepare-build.sh: clone the repositories, install the build tools and
#     dependencies, set up repo/ (holding the last release's packages, if
#     restored) and fetch Proxmox's unchanged packages
#   - select-steps.sh: what to build (STEPS: auto, all, or step names)
#   - build.sh --only <steps>, then record them in repo/SOURCES
#   - package-repo.sh --prune: drop the older package versions
# Results for the workflow in build/ci/: steps (built, comma-separated) and
# changed (true if the repository's index or manifest changed).
#
# Environment: STEPS (default auto), BUILD_UID (the workspace owner's UID),
# GITHUB_ACTIONS (for annotations). The workspace is /work.

set -euo pipefail

if [ "$(id -u)" = 0 ]; then
    : "${BUILD_UID:?BUILD_UID not set}"
    # apt as on a machine: the image's Docker tweaks keep the package lists
    # compressed and delete downloaded packages
    rm -f /etc/apt/apt.conf.d/docker-gzip-indexes /etc/apt/apt.conf.d/docker-clean
    apt-get update -q
    apt-get install -y -q --no-install-recommends sudo git ca-certificates
    # a user with that UID may exist already, e.g. podman's --userns=keep-id
    # adds the invoking user (getent fails with 2 if there's none)
    user=$(getent passwd "$BUILD_UID" | cut -d: -f1) || true
    if [ -z "$user" ]; then
        user=build
        useradd --create-home --uid "$BUILD_UID" --shell /bin/bash "$user"
    fi
    # a home of its own (podman's user has '/'), e.g. for gpg's ~/.gnupg
    home=$(getent passwd "$user" | cut -d: -f6)
    if [ "${home#/home/}" = "$home" ]; then
        home=/home/$user
        usermod --home "$home" "$user"
    fi
    mkdir -p "$home"
    chown "$BUILD_UID" "$home"
    echo "$user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/build
    chmod 0440 /etc/sudoers.d/build
    exec sudo -u "$user" -H --preserve-env=STEPS,GITHUB_ACTIONS "$0"
fi

cd /work
mkdir -p build/ci build-logs

./prepare-build.sh 2>&1 | tee -a build-logs/prepare-build.log

# the packages (their checksums are in the index) and the manifest: a rebuild
# with identical packages still records new commits, which must be published,
# or the next run rebuilds the same steps again
index() { cat repo/Packages repo/SOURCES 2>/dev/null | sha256sum | cut -d' ' -f1; }
before=$(index)

steps=$(./select-steps.sh select "${STEPS:-auto}" repo/SOURCES)
echo "$steps" > build/ci/steps
if [ -n "$steps" ]; then
    echo "=== building: $steps"
    ./build.sh --only "$steps"
    ./select-steps.sh record repo/SOURCES ${steps//,/ }
else
    echo "=== nothing to build"
fi

./package-repo.sh --prune repo

[ "$(index)" != "$before" ] && echo true > build/ci/changed || echo false > build/ci/changed
echo "=== repository changed: $(cat build/ci/changed)"
