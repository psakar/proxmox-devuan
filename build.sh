#!/bin/bash
# shellcheck disable=SC2024  # logs belong to the user: sudo's output is redirected as that user
# Build the Proxmox VE packages for Devuan (sysvinit/OpenRC) from the
# repositories in the current directory, as cloned by prepare-build.sh, into the
# local repository repo/, in dependency order (see openrc-devuan.md, Part C).
# Two steps add packages from Proxmox, not built here: its kernel
# (proxmox-default-kernel and the Proxmox packages it depends on), needed to
# install Proxmox VE, and its Secure Boot chain (proxmox-secure-boot-support:
# shim and GRUB, which trust Proxmox's signing key, so its kernel boots).
#
# Building installs build dependencies, including packages built here (e.g.
# pve-cluster, whose daemon pmxcfs needs the hostname to resolve to a
# non-loopback address). Two dependency cycles are bootstrapped by unpacking
# one package with dpkg --unpack --force-depends (its files, without running
# its maintainer scripts, e.g. starting a daemon), configured by apt after the
# build:
#   pve-cluster: its build needs libpve-access-control, which depends on it
#   pve-network: its build needs pve-firewall, which depends on it
#
# Usage: build.sh [--from <step>] [--only <step>[,<step>...]] [--keep] [--install]
#                 [--list] [--sources <step>]
#   --from <step>  start at this step (e.g. to resume after a failure)
#   --only <steps> build only these steps (comma-separated, or the option
#                  repeated), in build order
#   --keep         keep the build directories; by default a step removes them
#                  once its packages are in repo/ (a failed step keeps them)
#   --install      install pve-manager (and so everything) afterwards
#   --list         list the steps
#   --sources <step>
#                  print the step's changelog (whose version its packages get)
#                  and the repositories it's built from, e.g. to decide whether
#                  it needs rebuilding (select-steps.sh); proxmox-default-kernel
#                  and proxmox-secure-boot-support have neither, their packages
#                  come from Proxmox
#
# Versions come from the repositories' debian/changelog (+devuan<N>); bump them
# for a rebuild with changes, apt doesn't replace a package with another one of
# the same version. Logs: build-logs/<repo>.log and build-logs/build.log.

set -euo pipefail

BASE=$(pwd)
R=$BASE/repo
BUILD_REPO=$R/build-repo.sh
# the unchanged packages fetched from Proxmox's repository by prepare-build.sh
P=$BASE/repo-proxmox
LOG=$BASE/build-logs/build.log
NPROC=$(nproc)

STEPS=(
    libpve-rs-perl pve-common pve-qemu corosync-pve pve-cluster pve-firewall pve-network
    pve-storage ifupdown2 frr ksm-control-daemon lxc pve-lxc-syscalld pve-ha-manager
    qemu-server pve-container pve-manager proxmox-firewall proxmox-default-kernel
    proxmox-secure-boot-support proxmox-kernel-helper proxmox-ve
)

# The repositories a step is built from, if not just the one named like it:
# libpve-rs-perl and proxmox-firewall also use the local crates (see
# local_crates_patch); proxmox-default-kernel and proxmox-secure-boot-support
# are downloaded from Proxmox
declare -A STEP_SOURCES=(
    [libpve-rs-perl]="proxmox-perl-rs proxmox-rs proxmox-ve-rs perlmod"
    [proxmox-firewall]="proxmox-firewall proxmox-rs proxmox-ve-rs"
    [proxmox-default-kernel]=""
    [proxmox-secure-boot-support]=""
)
declare -A STEP_CHANGELOG=(
    [libpve-rs-perl]=proxmox-perl-rs/pve-rs/debian/changelog
    [proxmox-default-kernel]=""
    [proxmox-secure-boot-support]=""
)
step_sources() { echo "${STEP_SOURCES[$1]-$1}"; }
step_changelog() { echo "${STEP_CHANGELOG[$1]-$1/debian/changelog}"; }
is_step() { printf '%s\n' "${STEPS[@]}" | grep -qxF "$1"; }

FROM='' ONLY=() INSTALL=0 KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM=$2; shift ;;
        --only) IFS=', ' read -ra steps <<<"$2"; ONLY+=("${steps[@]}"); shift ;;
        --install) INSTALL=1 ;;
        --keep) KEEP=1 ;;
        --list) printf '%s\n' "${STEPS[@]}"; exit 0 ;;
        --sources)
            is_step "$2" || { echo "unknown step '$2', see --list" >&2; exit 2; }
            echo "changelog: $(step_changelog "$2")"
            echo "repositories: $(step_sources "$2")"
            exit 0 ;;
        -h|--help) sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "unknown option '$1', see --help" >&2; exit 2 ;;
    esac
    shift
done
for s in "$FROM" "${ONLY[@]}"; do
    if [ -n "$s" ] && ! is_step "$s"; then
        echo "unknown step '$s', see --list" >&2; exit 2
    fi
done

mkdir -p "$BASE/build-logs" "$BASE/build"
info() { printf '\n=== %s\n' "$*" | tee -a "$LOG"; }
die() { echo "ERROR: $*" | tee -a "$LOG" >&2; exit 1; }

[ -x "$BUILD_REPO" ] || die "$BUILD_REPO missing, run prepare-build.sh first"
[ -x "$P/fetch-proxmox.sh" ] || die "$P/fetch-proxmox.sh missing, run prepare-build.sh first"

refresh_repo() {
    "$R/update-index.sh"
    sudo apt-get update -q >/dev/null || die "apt-get update failed"
}

# The packages prepare-build.sh fetched from Proxmox into repo-proxmox/ must be visible
# to apt, or the builds fail on missing build dependencies.
check_fetched() {
    local prepare missing=() p
    prepare=$(dirname "$(readlink -f "$0")")/prepare-build.sh
    [ -f "$prepare" ] || die "$prepare missing"
    mapfile -t fetched < <(bash -c 'f=$1; set --; source "$f" >/dev/null; printf "%s\n" "${PROXMOX_PACKAGES[@]}"' _ "$prepare")
    [ ${#fetched[@]} -gt 0 ] || die "no package list in $prepare"
    for p in "${fetched[@]}"; do
        [ -n "$(apt-cache policy "$p" 2>/dev/null | sed -n 's/^ *Candidate: //p' | grep -v '(none)')" ] || missing+=("$p")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "not available to apt: ${missing[*]}; run prepare-build.sh again"
    fi
    echo "all ${#fetched[@]} packages from Proxmox available" | tee -a "$LOG"
}

# Dependencies from a control file's build dependencies (or a package's
# Depends), one per line, alternatives separated by '|'.
build_deps() { # <debian/control> <build profiles>
    DEB_BUILD_PROFILES="$2" perl -MDpkg::Control::Info -MDpkg::Deps -e '
        my $s = Dpkg::Control::Info->new($ARGV[0])->get_source;
        for my $f (qw(Build-Depends Build-Depends-Indep Build-Depends-Arch)) {
            my $d = deps_parse($s->{$f} // "", build_dep => 1,
                build_profiles => [split(/ /, $ENV{DEB_BUILD_PROFILES})], reduce_profiles => 1,
                reduce_arch => 1, host_arch => "amd64", build_arch => "amd64") or next;
            for my $x ($d->get_deps) {
                my @a = $x->isa("Dpkg::Deps::OR") ? $x->get_deps : ($x);
                print join("|", map { $_->{package} =~ s/:(native|any)$//r } @a), "\n";
            }
        }' "$1"
}
package_deps() { # <.deb>
    dpkg-deb -f "$1" Pre-Depends Depends | sed -n 's/^[A-Za-z-]*: //p' | perl -MDpkg::Deps -ne '
        my $d = deps_parse($_, reduce_arch => 1, host_arch => "amd64") or next;
        for my $x ($d->get_deps) {
            my @a = $x->isa("Dpkg::Deps::OR") ? $x->get_deps : ($x);
            print join("|", map { $_->{package} =~ s/:(native|any)$//r } @a), "\n";
        }'
}

# Install what's installable of the given dependencies (stdin), one by one;
# the others (Rust crates, packages not built yet) are skipped.
install_some() { # [exclude regex]
    local exclude=${1:-^$} dep alt
    while read -r dep; do
        for alt in ${dep//|/ }; do
            [[ $alt =~ $exclude ]] && continue
            sudo apt-get install -y -q --no-install-recommends "$alt" >>"$LOG" 2>&1 && break
        done
    done
}

# The local repositories' .deb of <package> with the highest version (by
# Debian version comparison, not file name), from repo/ (built here) or
# repo-proxmox/ (from Proxmox).
newest_deb() { # <package>
    local f v best='' best_v=''
    for f in "$R/$1"_*.deb "$P/$1"_*.deb; do
        [ -e "$f" ] || continue
        v=$(dpkg-deb -f "$f" Version)
        if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$best_v"; then
            best=$f best_v=$v
        fi
    done
    echo "$best"
}

# A package whose dependencies can't be installed yet: install what's
# installable of them, then unpack the package itself with --force-depends.
# Only its files are needed for the build; it gets configured (its maintainer
# scripts run) by fix_up, once its dependencies are there.
bootstrap_install() { # <package>
    local deb out
    deb=$(newest_deb "$1")
    [ -n "$deb" ] || die "no $1 in $R or $P"
    package_deps "$deb" | install_some
    echo "bootstrap: dpkg --unpack --force-depends $(basename "$deb")" | tee -a "$LOG"
    if ! out=$(sudo dpkg --unpack --force-depends "$deb" 2>&1); then
        echo "$out" | tee -a "$LOG" | tail -15 >&2
        die "unpacking $deb failed"
    fi
    echo "$out" >>"$LOG"
}

# Resolve the bootstrapped packages' dependencies with the packages just built,
# and configure them.
fix_up() {
    local out
    refresh_repo
    if ! out=$(sudo apt-get -f install -y -q 2>&1); then
        echo "$out" | tee -a "$LOG" | tail -20 >&2
        die "apt-get -f install failed, see $LOG"
    fi
    echo "$out" >>"$LOG"
    sudo dpkg --audit | tee -a "$LOG"
}

# pmxcfs (pve-cluster), installed as a build dependency, refuses to start if
# the hostname resolves to a loopback address only.
check_hostname() {
    local ip
    ip=$(getent hosts "$(hostname)" | awk '{print $1}' | head -1)
    case "$ip" in
        ''|127.*|::1) die "$(hostname) resolves to '${ip:-nothing}'; pve-cluster needs a non-loopback address, fix /etc/hosts" ;;
    esac
}

repo_build() { # <repo> [env assignments]
    local repo=$1; shift
    if ! env "$@" "$BUILD_REPO" "$BASE/$repo" | tee -a "$LOG"; then
        die "$repo failed, see build-logs/$repo.log; resume with --from $repo"
    fi
    # the packages are in repo/ now: remove the build directory and the
    # copies of the packages (the repositories' clean target)
    if [ $KEEP = 0 ]; then
        make -C "$BASE/$repo" clean </dev/null >>"$BASE/build-logs/$repo.log" 2>&1 || true
    fi
}

# Remove a build directory in build/ and its packages, which are in repo/ now.
clean_build_dir() { # <build dir>
    [ $KEEP = 0 ] || return 0
    local dir=$1 name version
    name=$(basename "$dir"); version=${name##*-}; name=${name%-*}
    rm -rf "$dir" "$BASE"/build/"$name"*_"$version"_*
}

# Build a package from its prepared build directory: patched debian/rules (no
# Debian crate registry, default CARGO_HOME) and dpkg-buildpackage -d, as the
# librust-* build dependencies are replaced by crates.io and local crates.
cargo_dir_build() { # <name> <build dir> <log name>
    local name=$1 dir=$2 log=$BASE/build-logs/$3.log
    sed -i -e '/prepare-debian .*cargo_registry/d' \
           -e 's|^export CARGO_HOME = .*|# CARGO_HOME: the default (~/.cargo), crates from crates.io|' "$dir/debian/rules"
    echo "=== $(date -Is) building $name in $dir" >>"$log"
    (cd "$dir" && PATH=/usr/local/bin:/usr/bin:/bin dpkg-buildpackage -b -us -uc -d) </dev/null >>"$log" 2>&1 \
        || die "$name failed, see build-logs/$3.log"
}

# cargo configuration using the crates of the given workspaces (e.g. the local
# proxmox-rs, with its Devuan changes) instead of the published ones
local_crates_patch() { # <workspace dir>...
    local ws crate_dir name
    echo '[patch.crates-io]'
    for ws in "$@"; do
        for crate_dir in "$ws"/*/; do
            [ -f "$crate_dir/Cargo.toml" ] || continue
            name=$(sed -n '/^\[package\]/,/^\[/s/^name *= *"\(.*\)"/\1/p' "$crate_dir/Cargo.toml" | head -1)
            [ -n "$name" ] && echo "$name = { path = \"${crate_dir%/}\" }"
        done
    done
}

step_pve-common() { repo_build pve-common WITH_TESTS=1; }

# libpve-rs-perl, built against the local proxmox-rs (with its Devuan
# changes), proxmox-ve-rs and perlmod crates instead of the published ones.
# Built first, without its tests: Proxmox's libproxmox-rs-perl, which
# pve-common's build needs, depends on libpve-rs-perl, and the tests are the
# only part of this build that needs libproxmox-rs-perl (its
# Proxmox::Lib::SslProbe), so the build needs no package from that cycle.
step_libpve-rs-perl() {
    local src=$BASE/proxmox-perl-rs/pve-rs version dir
    echo perlmod-bin | install_some
    build_deps "$src/debian/control" nocheck | install_some '^librust-|^dh-cargo$|^cargo$|^rustc$|^libproxmox-rs-perl$'
    version=$(dpkg-parsechangelog -l "$src/debian/changelog" -S Version)
    # built outside the repository: cargo also reads the .cargo/config.toml of
    # parent directories, and pve-rs/'s points at the Debian crate registry
    dir=$BASE/build/libpve-rs-perl-$version
    rm -rf "$dir" "$src/libpve-rs-perl-$version"
    make -C "$src" "libpve-rs-perl-$version" </dev/null >>"$BASE/build-logs/proxmox-perl-rs.log" 2>&1 \
        || die "preparing the libpve-rs-perl build directory failed"
    mv "$src/libpve-rs-perl-$version" "$dir"
    local_crates_patch "$BASE"/proxmox-rs "$BASE"/proxmox-ve-rs "$BASE"/perlmod > "$dir/.cargo/config.toml"
    DEB_BUILD_OPTIONS=nocheck cargo_dir_build libpve-rs-perl "$dir" proxmox-perl-rs
    cp "$BASE"/build/libpve-rs-perl*_"$version"_*.deb "$R/"
    refresh_repo
    echo "=== libpve-rs-perl: built $version" | tee -a "$LOG"
    clean_build_dir "$dir"
}

step_pve-qemu() { repo_build pve-qemu BUILD_PARALLEL="$NPROC"; }
# before pve-cluster, whose build and pmxcfs use corosync's libraries
step_corosync-pve() { repo_build corosync-pve BUILD_PARALLEL="$NPROC"; }

step_pve-cluster() {
    check_hostname
    local control=$BASE/pve-cluster/debian/control
    # with its tests, they generate IPCC.so/IPCConst.pm
    build_deps "$control" pkg.pve-cluster.lsbservice | install_some '^libpve-access-control$'
    bootstrap_install libpve-access-control
    repo_build pve-cluster WITH_TESTS=1 BUILD_PARALLEL=1 SKIP_BUILD_DEPS=1
    fix_up
}

step_pve-firewall() { repo_build pve-firewall; }

step_pve-network() {
    local control=$BASE/pve-network/debian/control
    build_deps "$control" "nocheck pkg.pve-network.lsbservice" | install_some '^pve-firewall$'
    bootstrap_install pve-firewall
    repo_build pve-network SKIP_BUILD_DEPS=1
    fix_up
}

step_pve-storage() { repo_build pve-storage; }
step_ifupdown2() { repo_build ifupdown2; }
step_frr() { repo_build frr BUILD_PARALLEL="$NPROC"; }
step_ksm-control-daemon() { repo_build ksm-control-daemon; }
step_lxc() { repo_build lxc BUILD_PARALLEL="$NPROC"; }

# pve-lxc-syscalld: its own .cargo config points at the Debian crate registry,
# and cargo also reads it from parent directories, so the build directory is
# moved out of the repository to build/.
step_pve-lxc-syscalld() {
    local src=$BASE/pve-lxc-syscalld version dir
    build_deps "$src/debian/control" "nocheck pkg.pve-lxc-syscalld.lsbservice" | install_some '^librust-|^dh-cargo$|^cargo$|^rustc$'
    version=$(dpkg-parsechangelog -l "$src/debian/changelog" -S Version)
    dir=$BASE/build/pve-lxc-syscalld-$version
    rm -rf "$dir" "$src/pve-lxc-syscalld-$version"
    make -C "$src" "pve-lxc-syscalld-$version" </dev/null >>"$BASE/build-logs/pve-lxc-syscalld.log" 2>&1 \
        || die "preparing the pve-lxc-syscalld build directory failed"
    mv "$src/pve-lxc-syscalld-$version" "$dir"
    rm -rf "$dir/.cargo"
    DEB_BUILD_PROFILES="nocheck pkg.pve-lxc-syscalld.lsbservice" DEB_BUILD_OPTIONS=nocheck \
        cargo_dir_build pve-lxc-syscalld "$dir" pve-lxc-syscalld
    cp "$BASE"/build/pve-lxc-syscalld*_"$version"_*.deb "$R/"
    refresh_repo
    echo "=== pve-lxc-syscalld: built $version" | tee -a "$LOG"
    clean_build_dir "$dir"
}

# proxmox-firewall: built outside the repository like libpve-rs-perl, against
# the local proxmox-rs (proxmox-log's syslog fallback, as there's no journald)
# and proxmox-ve-rs crates instead of the Debian crate registry
step_proxmox-firewall() {
    local src=$BASE/proxmox-firewall version dir
    build_deps "$src/debian/control" "nocheck pkg.proxmox-firewall.lsbservice" | install_some '^librust-|^dh-cargo$|^cargo$|^rustc$'
    version=$(dpkg-parsechangelog -l "$src/debian/changelog" -S Version)
    dir=$BASE/build/proxmox-firewall-$version
    rm -rf "$dir" "$src/proxmox-firewall-$version"
    make -C "$src" "proxmox-firewall-$version" </dev/null >>"$BASE/build-logs/proxmox-firewall.log" 2>&1 \
        || die "preparing the proxmox-firewall build directory failed"
    mv "$src/proxmox-firewall-$version" "$dir"
    mkdir -p "$dir/.cargo"
    local_crates_patch "$BASE"/proxmox-rs "$BASE"/proxmox-ve-rs > "$dir/.cargo/config.toml"
    # without the Debian registry's cargo setup, the binary is built for the
    # host, in target/release/ instead of target/<rust triple>/release/
    sed -i 's|^target/${env:DEB_HOST_RUST_TYPE}/release/|target/release/|' \
        "$dir/debian/proxmox-firewall.install"
    DEB_BUILD_PROFILES="nocheck pkg.proxmox-firewall.lsbservice" DEB_BUILD_OPTIONS="nocheck parallel=$NPROC" \
        cargo_dir_build proxmox-firewall "$dir" proxmox-firewall
    cp "$BASE"/build/proxmox-firewall_"$version"_*.deb "$R/"
    refresh_repo
    echo "=== proxmox-firewall: built $version" | tee -a "$LOG"
    clean_build_dir "$dir"
}

step_pve-ha-manager() { repo_build pve-ha-manager; }

# its build dependency pve-qemu-kvm (>= 11.1~) is only needed by the tests
step_qemu-server() { repo_build qemu-server RELAX_BUILD_DEPS=1; }

step_pve-container() { repo_build pve-container; }
step_pve-manager() { repo_build pve-manager BUILD_PARALLEL=1; }

# A Proxmox package and the Proxmox packages it depends on, downloaded from
# Proxmox's repository with the private apt configuration into repo/, as part
# of the build's result. The names are resolved from Proxmox's current index,
# so newer versions are picked up without changes here.
# usage: fetch_proxmox <package> [<regex: dependencies to leave out>]
fetch_proxmox() {
    local root=$1 skip=${2:-} A=$P/proxmox-fetch dir=$BASE/build/$1 lists closure pkgs=() index p cand f n=0
    local opts=(-o "Dir::Etc::SourceList=$A/etc/sources.list" -o "Dir::Etc::SourceParts=$A/empty"
                -o "Dir::Etc::Preferences=$A/etc/preferences" -o "Dir::Etc::PreferencesParts=$A/empty"
                -o "Dir::State::Lists=$A/state/lists" -o "Dir::Cache=$A/cache")
    "$A/apt.sh" update -q >>"$LOG" 2>&1 || die "updating Proxmox's package lists failed, see $LOG"
    lists=("$A"/state/lists/*download.proxmox.com_*Packages)
    [ -e "${lists[0]}" ] || die "no Proxmox package lists in $A/state/lists"
    # the dependency closure, limited to the packages whose candidate (with
    # the private configuration's pins) is Proxmox's: the others come from
    # Devuan, e.g. initramfs-tools, or udev, which Proxmox has too (systemd's)
    # but which is pinned to Devuan
    declare -A proxmox_versions=()
    while read -r p cand; do proxmox_versions["$p $cand"]=1; done \
        < <(awk '/^Package: / { p = $2 } /^Version: / { print p, $2 }' "${lists[@]}")
    mapfile -t closure < <(apt-cache "${opts[@]}" depends --recurse --no-recommends --no-suggests \
            --no-conflicts --no-breaks --no-replaces --no-enhances "$root" 2>>"$LOG" \
        | grep -E '^[a-z0-9]' | sort -u)
    for p in "${closure[@]}"; do
        cand=$(apt-cache "${opts[@]}" policy "$p" 2>/dev/null | sed -n 's/^ *Candidate: //p')
        [ -n "$skip" ] && [[ $p =~ ^($skip)$ ]] && continue
        [ -n "${proxmox_versions["$p $cand"]:-}" ] && pkgs+=("$p")
    done
    printf '%s\n' "${pkgs[@]}" | grep -qxF "$root" || die "$root not in Proxmox's index"
    # a kernel image is either signed or not (alternatives): only the signed
    # one, the unsigned is dropped where its -signed package is in the list
    mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | awk '{ p[NR] = $0; has[$0] = 1 }
        END { for (i = 1; i <= NR; i++) if (p[i] !~ /^proxmox-kernel-/ || !((p[i] "-signed") in has)) print p[i] }')
    echo "downloading ${pkgs[*]}" | tee -a "$LOG"
    rm -rf "$dir"; mkdir -p "$dir"
    (cd "$dir" && "$A/apt.sh" download "${pkgs[@]}") </dev/null >>"$LOG" 2>&1 || die "downloading failed, see $LOG"
    # only Proxmox's files (by name in its index), as a safeguard;
    # read once: a pipe from sed into grep -q fails under pipefail when grep
    # exits at the match and sed gets SIGPIPE
    index=$(sed -n 's|^Filename: .*/||p' "${lists[@]}" | sort -u)
    for f in "$dir"/*.deb; do
        [ -e "$f" ] || continue
        if grep -qxF "$(basename "$f")" <<<"$index"; then
            cp "$f" "$R/"; n=$((n + 1))
            echo "  $(basename "$f")" | tee -a "$LOG"
        fi
    done
    rm -rf "$dir"
    refresh_repo
    [ -n "$(apt-cache policy "$root" | sed -n 's/^ *Candidate: //p' | grep -v '(none)')" ] \
        || die "$root not available to apt from $R"
    echo "=== $root: $n packages from Proxmox added to $R" | tee -a "$LOG"
}

# Proxmox's kernel, needed to install Proxmox VE (pve-manager depends on
# proxmox-default-kernel): the meta package and the Proxmox packages it depends
# on (the kernel series, the kernel image, pve-firmware)
step_proxmox-default-kernel() { fetch_proxmox proxmox-default-kernel; }

# Proxmox's Secure Boot chain, for machines booting with Secure Boot (like
# upstream, not a dependency of proxmox-ve): its shim (signed by Microsoft,
# trusting Proxmox's key) and GRUB (signed by Proxmox), which load Proxmox's
# signed kernel; Debian's shim and GRUB only load Debian's. GRUB's 32-bit EFI
# target, an alternative in proxmox-grub's dependencies, is left out.
step_proxmox-secure-boot-support() { fetch_proxmox proxmox-secure-boot-support 'grub-efi-ia32.*'; }

# proxmox-kernel-helper (proxmox-boot-tool and the kernel hooks), and the
# proxmox-ve meta package, which depends on it, to install Proxmox VE as usual
step_proxmox-kernel-helper() { repo_build proxmox-kernel-helper; }
step_proxmox-ve() { repo_build proxmox-ve; }

# allow sourcing the functions, e.g. for testing
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

info "Checking the local repository"
# apt installs nothing while installed packages have unmet dependencies, e.g.
# after an interrupted build
if ! sudo apt-get check -q >/dev/null 2>&1; then
    sudo apt-get check -q 2>&1 | grep -vE '^(Reading|Building|Done)' >&2 || true
    die "installed packages have unmet dependencies; see what 'sudo apt --fix-broken install -s' proposes, apply it, then resume with --from"
fi
refresh_repo
check_fetched

started=0
[ -z "$FROM" ] && started=1
for step in "${STEPS[@]}"; do
    [ "$step" = "$FROM" ] && started=1
    [ $started = 1 ] || continue
    if [ ${#ONLY[@]} -gt 0 ] && ! printf '%s\n' "${ONLY[@]}" | grep -qxF "$step"; then
        continue
    fi
    info "$(date -Is) step $step"
    "step_$step"
done

if [ $INSTALL = 1 ]; then
    check_hostname
    info "Installing pve-manager"
    refresh_repo
    sudo apt-get install -y pve-manager 2>&1 | tee -a "$LOG"
    sudo dpkg --audit
fi

info "Done; packages in $R"
