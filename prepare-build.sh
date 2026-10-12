#!/bin/bash
# Prepare a Devuan 6 (excalibur) machine for building Proxmox VE for systemd-free
# systems (sysvinit/OpenRC), into the current directory:
#
#  1. clone the repositories needed for the build: those with Devuan changes
#     from their GitHub forks (branch feature/init-systems-refactoring, remote
#     'origin'), with Proxmox's repository as remote 'upstream', and perlmod
#     and proxmox-ve-rs, whose crates libpve-rs-perl is built against
#  2. install the build tools and the build dependencies Devuan provides
#  3. set up two local apt repositories: repo/ for the packages built here,
#     repo-proxmox/ for the unchanged packages from Proxmox's repository, with
#     the private apt configuration for fetching those, after checking
#     Proxmox's signing key
#  4. fetch the unchanged Proxmox packages the build and the installation need
#     into repo-proxmox/
#
# Needs git and sudo. Safe to run again: existing clones and packages are kept;
# the scripts and apt configuration are rewritten.
#
# Usage: prepare-build.sh [--with-planned] [--with-reference] [--no-deps] [--no-clone]
#   --with-planned    also clone the repositories with open plan items
#   --with-reference  also clone the unchanged repositories of the installed
#                     Proxmox packages into deps/, for reference
#   --no-deps         only clone, don't install or fetch anything
#   --no-clone        only install and fetch, don't clone
#
# Environment:
#   FORK_BASE      base URL of the forks (default: https://github.com/psakar)
#   UPSTREAM_BASE  base URL of Proxmox's repositories (default: https://git.proxmox.com/git)

set -euo pipefail

BASE=$(pwd)
FORK_BASE=${FORK_BASE:-https://github.com/psakar}
UPSTREAM_BASE=${UPSTREAM_BASE:-https://git.proxmox.com/git}
BRANCH=feature/init-systems-refactoring

# Proxmox's trixie release key, see https://pve.proxmox.com/wiki/Package_Repositories
KEY_URL=https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg
KEY_FPR=24B30F06ECC1836A4E5EFECBA7BCD1420BFE778E

# Repositories with Devuan changes, built here: name, and the upstream URL if it
# isn't $UPSTREAM_BASE/<name>.git
BUILD_REPOS=(
    pve-common pve-manager pve-cluster pve-ha-manager qemu-server pve-container
    pve-storage pve-firewall pve-network pve-lxc-syscalld lxc ifupdown2 pve-qemu
    proxmox-rs proxmox-perl-rs frr corosync-pve ksm-control-daemon
    proxmox-kernel-helper proxmox-ve proxmox-firewall
)
# Unchanged repositories the build needs as sources: libpve-rs-perl is built
# against their crates (with proxmox-rs'), cloned from Proxmox's repository
SOURCE_REPOS=(perlmod proxmox-ve-rs)

declare -A UPSTREAM_URL=(
    [proxmox-rs]=https://github.com/proxmox/proxmox-rs.git
)
# What the Devuan branch is based on, checked out when falling back to upstream
# (default: master); pve-qemu's is the 11.0.3-4 release on stable-11.0
declare -A BASE_REF=(
    [pve-qemu]=7fccdcf
)
# What to build from, for reproducible builds: a commit, tag or branch, checked
# out after cloning instead of the default (the fork's $BRANCH, or Proxmox's
# master). An existing clone is kept, with a warning if it's elsewhere.
# perlmod and proxmox-ve-rs: what libpve-rs-perl 0.15.3+devuan1 was built
# against; move them together with a changelog bump of proxmox-perl-rs.
declare -A REF=(
    [perlmod]=3a667956097b361a9ef40fa8a2f6c0e26711b025
    [proxmox-ve-rs]=61125e1fbf8d0f1a6385153bfd6eae36254b9b89
)

# Repositories with open plan items (init-system work still to do), cloned from
# Proxmox's repository; ui/ holds several repositories
PLANNED_REPOS=(
    pve-vgpu-helper proxmox-widget-toolkit zfsonlinux ceph
)
PLANNED_UI_REPOS=(
    pve-yew-mobile-gui proxmox-yew-comp proxmox-yew-widget-toolkit
    proxmox-yew-widget-toolkit-assets proxmox-yew-widget-toolkit-examples
    proxmox-wasm-builder pmg-yew-quarantine-gui
)

# Unchanged sources of the packages installed from Proxmox's repository, for
# reference; proxmox-acme at the top level, the others in deps/
REFERENCE_TOP_REPOS=(proxmox-acme)
REFERENCE_DEPS_REPOS=(
    extjs fonts-font-logos libjs-qrcodejs librados2-perl lxcfs novnc-pve
    proxmox-backup proxmox-backup-qemu proxmox-biome proxmox-enterprise-support
    proxmox-i18n proxmox-mail-forward proxmox-mini-journalreader
    proxmox-websocket-tunnel pve-access-control pve-apiclient pve-docs
    pve-edk2-firmware pve-guest-common pve-http-server pve-xtermjs spiceterm vncterm
)

# Build tools (Devuan); rustc-web/cargo-web: the Rust packages need Rust 1.85+
TOOLS=(
    git build-essential devscripts equivs fakeroot lintian apt-utils dpkg-dev
    debhelper meson ninja-build pkgconf curl gpg gpgv
    rsync  # copies the sources into the build directory (pve-manager, pve-firewall)
    wget   # pve-manager's 'make update' of the appliance index (aplinfo)
    rustc-web cargo-web rustfmt-web
    # native libraries of the Rust builds' -sys crates (normally pulled in by
    # the librust-*-dev packages, which aren't used): bindgen/clang-sys,
    # nettle-sys, openssl-sys, apt-pkg-native
    libclang-dev nettle-dev libgmp-dev libssl-dev libapt-pkg-dev
)

# Build dependencies of the repositories built here that Devuan provides (from
# their debian/control with the nocheck and lsbservice profiles). Not included:
# packages built here or taken from Proxmox (installed per build by
# build-repo.sh from the local repository), librust-* crates (the Rust builds
# use crates.io), and Devuan's rustc/cargo (rustc-web/cargo-web instead).
BUILD_DEPS=(
    bash-completion check debhelper dh-apparmor dh-cargo dh-python docbook2x
    doxygen graphviz libacl1-dev libaio-dev libanyevent-perl libapparmor-dev
    libapt-pkg-perl libasound2-dev libattr1-dev libcap-dev libcap-ng-dev
    libclass-methodmaker-perl libclone-perl libcmap-dev
    libcorosync-common-dev libcpg-dev libcurl4-gnutls-dev libdbus-1-dev
    libdevel-cycle-perl libdigest-hmac-perl libdrm-dev libepoxy-dev
    libfdt-dev libfile-chdir-perl libfile-readbackwards-perl
    libfile-slurp-perl libfilesys-df-perl libfuse3-dev libfuse-dev
    libgbm-dev libglib2.0-dev libglib-perl libgnutls28-dev libgtk3-perl
    libhttp-daemon-perl libhttp-message-perl libio-multiplex-perl
    libiscsi-dev libjpeg-dev libjson-c-dev libjson-perl
    liblinux-inotify2-perl libnetaddr-ip-perl libnet-dbus-perl
    libnetfilter-conntrack-dev libnetfilter-log-dev libnet-ip-perl
    libnet-subnet-perl libnuma-dev libpci-dev libpixman-1-dev libpng-dev
    libpod-parser-perl libposix-strptime-perl libpulse-dev libqb-dev
    libquorum-dev librbd-dev librrd-dev librrds-perl libseccomp-dev
    libslirp-dev libsndio-dev libspice-protocol-dev libspice-server-dev
    libsqlite3-dev libstring-shellquote-perl libsystemd-dev libtemplate-perl
    libtest-differences-perl libtest-mockmodule-perl liburing-dev
    liburi-perl libusb-1.0-0-dev libusbredirparser-dev libuuid-perl
    libvirglrenderer-dev libxkbcommon-dev libxml-libxml-perl
    libyaml-libyaml-perl libzstd-dev lintian linux-libc-dev meson perl
    pkgconf pkg-config python3 python3-all python3-docutils python3-minimal
    python3-setuptools python3-sphinx python3-sphinx-rtd-theme python3-venv
    python3-wheel quilt rrdcached sq sqlite3 systemd-dev unzip
    uuid-dev xfslibs-dev
)

# Packages taken unchanged from Proxmox's repository: build and runtime
# dependencies without anything init-system specific
PROXMOX_PACKAGES=(
    libpve-access-control libpve-guest-common-perl librados2-perl
    libpve-apiclient-perl libpve-http-server-perl libproxmox-rs-perl perlmod-bin
    libproxmox-acme-perl libproxmox-acme-plugins
    spiceterm vncterm libjs-extjs fonts-font-logos libjs-qrcodejs novnc-pve
    pve-edk2-firmware-ovmf pve-edk2-firmware-legacy
    proxmox-backup-client proxmox-backup-file-restore
    libproxmox-backup-qemu0 libproxmox-backup-qemu0-dev
    proxmox-websocket-tunnel pve-xtermjs proxmox-termproxy
    proxmox-widget-toolkit pve-yew-mobile-gui pve-i18n pve-yew-mobile-i18n
    pve-docs pve-doc-generator proxmox-mail-forward
    proxmox-enterprise-support-keyring proxmox-firewall-data proxmox-frr-templates
    proxmox-biome
    zfsutils-linux libzfs7linux libzpool7linux libnvpair3linux libuutil3linux
    ceph-common ceph-fuse librados2 librbd1 libcephfs2 librgw2 libradosstriper1
    librados-dev librbd-dev
    libknet1t64 libknet-dev libnozzle1t64 libnozzle-dev
    python3-ceph-argparse python3-ceph-common python3-cephfs python3-rados
    python3-rbd python3-rgw
)

WITH_PLANNED=0 WITH_REFERENCE=0 DO_DEPS=1 DO_CLONE=1
for arg in "$@"; do
    case "$arg" in
        --with-planned) WITH_PLANNED=1 ;;
        --with-reference) WITH_REFERENCE=1 ;;
        --no-deps) DO_DEPS=0 ;;
        --no-clone) DO_CLONE=0 ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "unknown option '$arg', see --help" >&2; exit 2 ;;
    esac
done

info() { printf '\n=== %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; WARNINGS+=("$*"); }
WARNINGS=()

upstream_url() { echo "${UPSTREAM_URL[$1]:-$UPSTREAM_BASE/$1.git}"; }

# Check out <name>'s REF, if any, in the fresh clone <dir>.
checkout_ref() {
    local name=$1 dir=$2 ref=${REF[$1]:-}
    [ -n "$ref" ] || return 0
    git -C "$dir" checkout -q "$ref" || { echo "ERROR: $dir: no $ref to check out (REF)" >&2; exit 1; }
    echo "$dir: checked out $ref"
}

# Warn if the existing clone <dir> isn't at <name>'s REF.
check_ref() {
    local name=$1 dir=$2 ref=${REF[$1]:-} want
    [ -n "$ref" ] || return 0
    want=$(git -C "$dir" rev-parse -q --verify "$ref^{commit}" 2>/dev/null) || want=''
    if [ "$(git -C "$dir" rev-parse HEAD)" != "$want" ]; then
        warn "$dir: not at $ref (REF), kept as it is"
    fi
}

# Clone from upstream into <dir>, keeping an existing clone.
clone_upstream() {
    local name=$1 dir=$2 url=${3:-$(upstream_url "$1")}
    if [ -e "$dir/.git" ]; then
        echo "$dir: exists, kept"
        check_ref "$name" "$dir"
        return
    fi
    mkdir -p "$(dirname "$dir")"
    git clone -q "$url" "$dir"
    git -C "$dir" remote rename origin upstream
    echo "$dir: cloned from $url (remote 'upstream')"
    checkout_ref "$name" "$dir"
}

# Clone a repository with Devuan changes: the fork's feature branch, with
# Proxmox's repository as 'upstream'. Without a fork (yet), fall back to
# upstream and warn, as the build then lacks the Devuan changes.
clone_build_repo() {
    local name=$1 fork="$FORK_BASE/$1.git"
    if [ -e "$name/.git" ]; then
        echo "$name: exists, kept ($(git -C "$name" branch --show-current))"
        check_ref "$name" "$name"
        return
    fi
    if git ls-remote --exit-code --heads "$fork" "$BRANCH" >/dev/null 2>&1; then
        git clone -q --branch "$BRANCH" "$fork" "$name"
        git -C "$name" remote add upstream "$(upstream_url "$name")"
        git -C "$name" fetch -q upstream
        echo "$name: cloned from $fork ($BRANCH), remote 'upstream' added"
        checkout_ref "$name" "$name"
    else
        clone_upstream "$name" "$name"
        if [ -n "${BASE_REF[$name]:-}" ]; then
            git -C "$name" checkout -q "${BASE_REF[$name]}"
            echo "$name: checked out ${BASE_REF[$name]}"
        fi
        warn "$name: $fork not reachable or without branch $BRANCH; cloned Proxmox's repository instead, WITHOUT the Devuan changes (without an SSH key for GitHub, use FORK_BASE=https://github.com/psakar)"
    fi
}

clone_all() {
    info "Cloning the repositories with Devuan changes into $BASE"
    for r in "${BUILD_REPOS[@]}"; do clone_build_repo "$r"; done
    for r in "${SOURCE_REPOS[@]}"; do clone_upstream "$r" "$r"; done

    if [ $WITH_PLANNED = 1 ]; then
        info "Cloning the repositories with open plan items"
        for r in "${PLANNED_REPOS[@]}"; do clone_upstream "$r" "$r"; done
        for r in "${PLANNED_UI_REPOS[@]}"; do clone_upstream "$r" "ui/$r" "$UPSTREAM_BASE/ui/$r.git"; done
    fi

    if [ $WITH_REFERENCE = 1 ]; then
        info "Cloning the unchanged repositories for reference"
        for r in "${REFERENCE_TOP_REPOS[@]}"; do clone_upstream "$r" "$r"; done
        for r in "${REFERENCE_DEPS_REPOS[@]}"; do clone_upstream "$r" "deps/$r"; done
    fi
}

check_devuan() {
    . /etc/os-release
    if [ "${ID:-}" != devuan ]; then
        warn "this isn't Devuan (ID=${ID:-unknown}); continuing anyway"
    elif [ "${VERSION_CODENAME:-}" != excalibur ]; then
        warn "this is Devuan ${VERSION_CODENAME:-?}, the build was set up on excalibur"
    fi
}

install_packages() {
    info "Installing the build tools and build dependencies"
    # apt installs nothing while installed packages have unmet dependencies,
    # e.g. after an interrupted build that installed some built packages
    if ! sudo apt-get check -q >/dev/null 2>&1; then
        echo "ERROR: installed packages have unmet dependencies (apt-get check):" >&2
        sudo apt-get check -q 2>&1 | grep -vE '^(Reading|Building|Done)' >&2 || true
        echo "See what 'sudo apt --fix-broken install -s' proposes and apply it, then run this again." >&2
        exit 1
    fi
    sudo apt-get update -q
    sudo apt-get install -y -q --no-install-recommends "${TOOLS[@]}" "${BUILD_DEPS[@]}"
}

# The two local apt repositories: repo/ for the packages built here, with the
# script for building into it, and repo-proxmox/ for the unchanged packages
# from Proxmox's repository, with the script and private apt configuration for
# fetching them.
setup_repo() {
    local R=$BASE/repo P=$BASE/repo-proxmox A=$BASE/repo-proxmox/proxmox-fetch dir
    info "Setting up the local repositories $R and $P"
    mkdir -p "$R" "$P" "$BASE/build-logs"
    mkdir -p "$A"/{etc,keys,empty,state/lists/partial,cache/archives/partial}

    for dir in "$R" "$P"; do
        cat > "$dir/update-index.sh" <<'EOF'
#!/bin/sh
# regenerate the local repository's index after adding packages
# only the packages directly in this directory, not e.g. proxmox-fetch/'s cache
cd "$(dirname "$0")" && apt-ftparchive packages . \
    | awk -v RS= -v ORS='\n\n' '$0 ~ /\nFilename: \.\/[^\/\n]+\n/' > Packages && gzip -9kf Packages
EOF
    done

    cat > "$A/apt.sh" <<'EOF'
#!/bin/sh
# apt-get with the private configuration (system dpkg status, own sources and cache);
# the package lists uncompressed, as fetch-proxmox.sh and build.sh read them
# (e.g. Docker's Debian-style images set Acquire::GzipIndexes)
A=$(cd "$(dirname "$0")" && pwd)
exec apt-get -o Dir::Etc::SourceList=$A/etc/sources.list -o Dir::Etc::SourceParts=$A/empty \
    -o Dir::Etc::Preferences=$A/etc/preferences -o Dir::Etc::PreferencesParts=$A/empty \
    -o Dir::State::Lists=$A/state/lists -o Dir::Cache=$A/cache -o Dir::Cache::Archives=$A/cache/archives \
    -o Acquire::GzipIndexes=false -o Debug::NoLocking=1 "$@"
EOF

    cat > "$P/fetch-proxmox.sh" <<'EOF'
#!/bin/bash
# Download packages from Proxmox's repository with the private apt configuration
# and add them to this local repository (repo-proxmox/). Only the named packages
# are downloaded (not their dependencies); apt checks them against the signed
# index.
R=$(cd "$(dirname "$0")" && pwd); A=$R/proxmox-fetch
L=$(dirname "$R")/build-logs/proxmox-fetch.log
$A/apt.sh update -q >>$L 2>&1
cd $A/cache/archives
for p in "$@"; do
    $A/apt.sh download "$p" >>$L 2>&1 && echo "fetched $p" || echo "NOT fetchable: $p"
done
names=$(cat $A/state/lists/*download.proxmox.com_*Packages | sed -n 's|^Filename: .*/||p' | sort -u)
for f in $A/cache/archives/*.deb; do
    [ -e "$f" ] || continue
    echo "$names" | grep -qxF "$(basename "$f")" && cp -n "$f" $R/
done
$R/update-index.sh && sudo apt-get update -q >/dev/null || { echo "ERROR: apt-get update failed" >&2; exit 1; }
EOF

    cat > "$R/build-repo.sh" <<'EOF'
#!/bin/bash
# Build a Proxmox repository's packages for Devuan (lsbservice and nocheck
# build profiles) and add them to the local repository.
# usage: build-repo.sh <repo dir> [make target (default: deb)]
# env: WITH_TESTS=1 (run the tests), BUILD_PARALLEL=<n>, RELAX_BUILD_DEPS=1
#      (circular build dependencies: install what's installable, skip the
#      check), SKIP_BUILD_DEPS=1 (the caller installed them, e.g. a package
#      only unpacked for bootstrapping a cycle: skip installing and the check)
set -o pipefail
R=$(cd "$(dirname "$0")" && pwd)
LOGDIR=$(dirname "$R")/build-logs
mkdir -p $LOGDIR
dir=$(realpath "$1"); target=${2:-deb}
name=$(basename "$dir")
log=$LOGDIR/$name.log
cd "$dir" || exit 1

control=$(ls debian/control 2>/dev/null || ls */debian/control 2>/dev/null | head -1)
src=$(sed -n 's/^Source: *//p' "$control" | head -1)
nocheck=${WITH_TESTS:+}; [ -z "$WITH_TESTS" ] && nocheck="nocheck"
# the repository's own lsbservice profile name, as defined in its debian/rules
profile=$(grep -ohE 'pkg\.[a-z0-9.+-]+\.lsbservice' $(dirname "$control")/rules 2>/dev/null | head -1)
profile=${profile:-pkg.$src.lsbservice}
export DEB_BUILD_PROFILES="${nocheck:+$nocheck }$profile"
export DEB_BUILD_OPTIONS="${nocheck}${BUILD_PARALLEL:+ parallel=$BUILD_PARALLEL}"

echo "=== $(date -Is) building $name (source $src), profiles: $DEB_BUILD_PROFILES" | tee -a $log

if [ -n "$RELAX_BUILD_DEPS" ]; then
    sudo apt-get update -q >/dev/null || { echo "ERROR: apt-get update failed" | tee -a $log >&2; exit 1; }
    deps=$(perl -MDpkg::Control::Info -MDpkg::Deps -e 'my $s=Dpkg::Control::Info->new($ARGV[0])->get_source; for my $f (qw(Build-Depends Build-Depends-Indep Build-Depends-Arch)) { my $d=deps_parse($s->{$f}//"", build_dep=>1, build_profiles=>[split(/ /, $ENV{DEB_BUILD_PROFILES})], reduce_profiles=>1, reduce_arch=>1, host_arch=>"amd64", build_arch=>"amd64") or next; for my $x ($d->get_deps) { my @a = $x->isa("Dpkg::Deps::OR") ? $x->get_deps : ($x); print join("|", map { $_->{package} =~ s/:(native|any)$//r } @a), "\n" } }' "$control")
    for dep in $deps; do
        for alt in ${dep//|/ }; do
            sudo apt-get install -y -q --no-install-recommends "$alt" >>$log 2>&1 && break
            echo "  build dependency not installable now: $alt" | tee -a $log
        done
    done
    mkdir -p ~/.config/dpkg
    echo "no-check-builddeps" > ~/.config/dpkg/buildpackage.conf
    trap 'rm -f ~/.config/dpkg/buildpackage.conf' EXIT
elif [ -n "$SKIP_BUILD_DEPS" ]; then
    # dpkg's check doesn't count unpacked (not configured) packages
    mkdir -p ~/.config/dpkg
    echo "no-check-builddeps" > ~/.config/dpkg/buildpackage.conf
    trap 'rm -f ~/.config/dpkg/buildpackage.conf' EXIT
else
    sudo apt-get update -q >/dev/null || { echo "ERROR: apt-get update failed" | tee -a $log >&2; exit 1; }
    (cd /tmp && sudo mk-build-deps -i -r --build-profiles "${DEB_BUILD_PROFILES// /,}" \
        -t "apt-get -y --no-install-recommends -o Debug::pkgProblemResolver=yes" "$dir/$control") 2>&1 | tee -a $log | grep -E "^E:|unmet|Unable|newly installed" || true
fi

stamp=$(mktemp); sleep 1
# build directories are only created if missing, so stale ones would hide source changes
# no terminal input: e.g. pve-qemu's Makefile runs an interactive git clean -i,
# which then lists and keeps the files instead of waiting for an answer
make clean </dev/null >>$log 2>&1 || true
make $target </dev/null 2>&1 | tee -a $log | grep -E "dpkg-buildpackage: (error|info: binary-only)|^E: |make: \*\*\*|error:" | tail -5
rc=${PIPESTATUS[0]}
debs=$(find "$dir" -maxdepth 2 -name '*.deb' -newer $stamp)
rm -f $stamp
if [ -z "$debs" ] || [ "$rc" -ne 0 ]; then
    # e.g. lintian errors fail make after the packages were built
    echo "=== $name: no packages added (make rc=$rc, built: $(for d in $debs; do basename $d; done | tr '\n' ' '))" | tee -a $log
    exit 1
fi
cp $debs $R/ && $R/update-index.sh && sudo apt-get update -q >/dev/null || { echo "ERROR: apt-get update failed" >&2; exit 1; }
echo "=== $name: built (make rc=$rc): $(for d in $debs; do basename $d; done | tr '\n' ' ')" | tee -a $log
EOF

    cat > "$A/etc/sources.list" <<EOF
deb http://deb.devuan.org/merged excalibur main non-free-firmware
deb http://deb.devuan.org/merged excalibur-security main non-free-firmware
deb http://deb.devuan.org/merged excalibur-updates main non-free-firmware
deb [trusted=yes] file:$R ./
deb [trusted=yes] file:$P ./
deb [signed-by=$A/keys/proxmox-release-trixie.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription
deb [signed-by=$A/keys/proxmox-release-trixie.gpg] http://download.proxmox.com/debian/ceph-squid trixie no-subscription
deb [signed-by=$A/keys/proxmox-release-trixie.gpg] http://download.proxmox.com/debian/devel trixie main
EOF

    cat > "$A/etc/preferences" <<'EOF'
# Private apt configuration for picking packages from Proxmox's repository
# into the local repository; the system's apt doesn't use Proxmox's repository.

# the local repositories (our builds, and what was fetched already) always win
Package: *
Pin: origin ""
Pin-Priority: 1001

# Proxmox's repository: only where Devuan doesn't have a suitable version
Package: *
Pin: origin download.proxmox.com
Pin-Priority: 100

# never take these from Proxmox: systemd, and the packages built here with the
# init-system changes
Package: systemd systemd-* libsystemd* udev libudev* libpam-systemd libnss-systemd libnss-myhostname
Pin: origin download.proxmox.com
Pin-Priority: -1

Package: libpve-common-perl pve-manager pve-cluster libpve-cluster-perl libpve-cluster-api-perl libpve-notify-perl pve-ha-manager pve-ha-simulator qemu-server pve-container libpve-storage-perl pve-firewall libpve-network-perl libpve-network-api-perl pve-lxc-syscalld lxc-pve lxc-pve-dev libpve-rs-perl pve-qemu-kvm ifupdown2 frr frr-* corosync corosync-* libcfg* libcmap* libcorosync-common* libcpg* libquorum* libsam* libvotequorum* ksm-control-daemon proxmox-kernel-helper proxmox-ve proxmox-firewall
Pin: origin download.proxmox.com
Pin-Priority: -1

# Proxmox's packages need Ceph 19 (squid) libraries, Devuan has 18 (reef)
Package: librados* librbd* libcephfs* librgw* libradosstriper* libceph* python3-ceph* python3-rados python3-rbd python3-cephfs python3-rgw ceph-common ceph-fuse libsqlite3-mod-ceph
Pin: origin download.proxmox.com
Pin-Priority: 600

# Proxmox's corosync needs kronosnet 1.32 or newer, Devuan has 1.31
Package: libknet* libnozzle*
Pin: origin download.proxmox.com
Pin-Priority: 600
EOF

    chmod +x "$R/update-index.sh" "$P/update-index.sh" "$P/fetch-proxmox.sh" "$R/build-repo.sh" "$A/apt.sh"
    "$R/update-index.sh"
    "$P/update-index.sh"

    # the system's apt uses the local repositories (not Proxmox's)
    printf 'deb [trusted=yes] file:%s ./\n' "$R" "$P" | sudo tee /etc/apt/sources.list.d/proxmox-devuan-local.list >/dev/null
}

# Proxmox's signing key, checked by its fingerprint before use
setup_key() {
    local key=$BASE/repo-proxmox/proxmox-fetch/keys/proxmox-release-trixie.gpg tmp
    info "Checking Proxmox's signing key"
    if [ ! -s "$key" ]; then
        tmp=$(mktemp)
        curl -sfL "$KEY_URL" -o "$tmp"
        mv "$tmp" "$key"
    fi
    if ! gpg --show-keys --with-colons "$key" 2>/dev/null | grep -q "^fpr:*$KEY_FPR:"; then
        rm -f "$key"
        echo "ERROR: $KEY_URL doesn't contain the expected key $KEY_FPR" >&2
        exit 1
    fi
    echo "key $KEY_FPR (Proxmox Trixie Release Key) OK"
}

fetch_proxmox() {
    info "Fetching the unchanged packages from Proxmox's repository into repo-proxmox/"
    local out
    out=$("$BASE/repo-proxmox/fetch-proxmox.sh" "${PROXMOX_PACKAGES[@]}")
    echo "fetched: $(grep -c '^fetched' <<<"$out" || true) of ${#PROXMOX_PACKAGES[@]}"
    while read -r line; do
        [ -n "$line" ] && warn "$line"
    done < <(grep '^NOT' <<<"$out" || true)
    sudo apt-get update -q >/dev/null
    # what the builds need must be visible to the system's apt now
    local p missing=()
    for p in "${PROXMOX_PACKAGES[@]}"; do
        [ -n "$(apt-cache policy "$p" 2>/dev/null | sed -n 's/^ *Candidate: //p' | grep -v '(none)')" ] || missing+=("$p")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: not available to apt after fetching: ${missing[*]}" >&2
        exit 1
    fi
    echo "all ${#PROXMOX_PACKAGES[@]} available to apt"
}

# allow sourcing the functions, e.g. for testing
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

cd "$BASE"
[ $DO_CLONE = 1 ] && clone_all
if [ $DO_DEPS = 1 ]; then
    check_devuan
    install_packages
    setup_repo
    setup_key
    fetch_proxmox
fi

info "Done"
if [ ${#WARNINGS[@]} -gt 0 ]; then
    printf 'WARNING: %s\n' "${WARNINGS[@]}"
fi
cat <<EOF

Next: build all packages into repo/ (see ./build.sh --help):
  ./build.sh
EOF
