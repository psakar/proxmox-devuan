# Building Proxmox VE for Devuan 6 with OpenRC

The changes the packages are built with: `openrc-devuan.md`. Installing the
result: `INSTALL.md`.

Three scripts in `~/proxmox-devuan` automate the build; run them from the
directory to work in:

- `prepare-build.sh` clones the repositories (Devuan branches from the
  GitHub forks `https://github.com/psakar/<name>`, Proxmox's as `upstream`),
  installs the build tools and Devuan build dependencies, sets up `repo/`
  with the signature-checked Proxmox fetch, and fetches the unchanged
  Proxmox packages.
- `build.sh` builds everything in the order below, with the special builds
  and the two bootstraps, into `repo/`; `--from <step>` resumes, `--install`
  installs pve-manager afterwards. Two steps build nothing, they download
  from Proxmox into `repo/`: `proxmox-default-kernel` its kernel
  (proxmox-default-kernel and the Proxmox packages it depends on: the
  kernel series package, the kernel image, pve-firmware), as installing
  Proxmox VE needs it, and `proxmox-secure-boot-support` its Secure Boot
  chain (shim and GRUB, see `INSTALL.md`, "UEFI with Secure Boot"). The
  last two, `proxmox-kernel-helper` and `proxmox-ve`, build the packages
  for `apt install proxmox-ve`.
- `update-repo.sh` copies `repo/` to `/srv/proxmox-devuan-repo` on an
  install machine (`REMOTE_MACHINE`, by default `root@pve2`) with scp, or
  with `rsync --delete` (`--rsync`), and gives it to `_apt`; `--upgrade`
  then runs `apt update && apt full-upgrade` there (see "Installing" and "Updating
  after a rebuild" below).

For publishing, the GitHub Actions workflow `.github/workflows/build-repo.yml`
builds the same way in a Devuan container and releases `repo/` as a signed
tarball, with two more scripts (see "Building with GitHub Actions"):

- `select-steps.sh` decides which `build.sh` steps an incremental build
  runs, and records what was built in `repo/SOURCES`.
- `package-repo.sh` removes older package versions from `repo/`, signs it
  (`Release`, `InRelease`, `Release.gpg`) and packs it.

Two more scripts check what Proxmox has released since the last build (see
"Checking upstream releases"):

- `upstream-tags.sh` tags Proxmox's latest release of each package in the
  clones.
- `upstream-systemd-scan.sh` lists the systemd-related changes in the
  upstream commits the build lacks.

The sections below describe what they do.

## Environment

- Devuan 6 excalibur amd64 with OpenRC, rsyslog, eudev and cgroup v2.
- Repositories cloned from `https://git.proxmox.com/git/<name>.git`, as remote
  `upstream` in the top-level repositories (proxmox-rs from
  `https://github.com/proxmox/proxmox-rs.git`), with the changed ones on
  `feature/init-systems-refactoring`, pushed to and tracking their GitHub
  forks `https://github.com/psakar/<name>` (remote `origin`; ifupdown2's, frr's,
  proxmox-kernel-helper's and proxmox-ve's are plain repositories, as
  Proxmox has no GitHub mirror of them). All changed repositories are in
  `~/proxmox-devuan/<name>`, as are those with open plan items (pve-vgpu-helper, proxmox-widget-toolkit, `ui/`, and
  zfsonlinux and ceph, out of scope for now). `~/proxmox-devuan/deps/` keeps only
  the 23 unchanged repositories of installed packages (see
  `repositories.md`); the others were deleted on 2026-10-03.
- Build tools: `build-essential devscripts equivs fakeroot lintian
  apt-utils`, plus `rustc-web` 1.96 (replaces Devuan's `rustc`/`cargo`)
  for the Rust packages.
- **No elogind PAM session support** (`libpam-elogind`) on the build
  machine. Its dependency `libelogind-compat` replaces `libsystemd0`
  (`Provides: libsystemd0 (= 255.17)`), and installing it removes
  `libsystemd-dev`, which needs the real `libsystemd0` of the same
  version. pve-qemu, pve-lxc-syscalld and corosync-pve build-depend on
  `libsystemd-dev`, so they can't be built while it's installed (their
  `<pkg>-build-deps` package is removed with it). Devuan's `dummy-logind`
  satisfies logind dependencies instead; to go back:
  `apt install libsystemd0 libsystemd-dev dummy-logind`. On the install
  machines `libpam-elogind` should be fine: `libelogind-compat`'s
  `libsystemd.so.0` exports the `sd_journal_stream_fd` pve-qemu-kvm links
  (not tested with a running VM).
- **Two local apt repositories,** both enabled in
  `/etc/apt/sources.list.d/proxmox-devuan-local.list`
  (`deb [trusted=yes] file:<dir> ./`):
  - `repo/`: the build's result: the packages built here (`+devuan<N>`
    versions), with `build-repo.sh`, and Proxmox's kernel packages added by
    `build.sh`'s last step;
  - `repo-proxmox/`: the unchanged packages fetched from Proxmox's
    repository, with `fetch-proxmox.sh` and the private fetch
    configuration `proxmox-fetch/`;
  - each has an `update-index.sh` that regenerates its `Packages(.gz)` with
    `apt-ftparchive`, from the `.deb` files directly in it;
  - `/etc/apt/preferences.d/proxmox-devuan-local` keeps the system's apt
    off Proxmox's shim and GRUB in `repo/` (versions matching `+pmx<N>`,
    from `proxmox-secure-boot-support`): without Proxmox's repository, an
    upgrade would replace `grub-common` with Proxmox's and remove `grub-pc`,
    which needs Devuan's version.
- **Fetching unchanged Proxmox packages**
  (`repo-proxmox/fetch-proxmox.sh pkg…`):
  - `proxmox-fetch/apt.sh` runs apt-get with a private configuration: its
    own sources list, preferences, lists and cache. The system's apt never
    sees Proxmox's repository.
  - Sources: Devuan, both local repositories, and download.proxmox.com `pve
    trixie pve-no-subscription`, `ceph-squid trixie no-subscription` and
    `devel trixie main`. They're signed by
    `proxmox-fetch/keys/proxmox-release-trixie.gpg`, whose fingerprint
    `prepare-build.sh` checks.
  - Pins:

    | Packages | Origin | Priority |
    |---|---|---|
    | everything | the local repositories (origin "") | 1001 |
    | everything | download.proxmox.com | 100 |
    | systemd family | download.proxmox.com | -1 |
    | every package built here | download.proxmox.com | -1 |
    | Ceph 19 client libraries | download.proxmox.com | 600 |

  - Only the named packages are downloaded (`apt-get download`), checked
    against the signed index, and copied into `repo-proxmox/`.
- **Versions:** every package built here has a local version suffix
  (`+devuan1`, `+devuan2` …) on top of Proxmox's version; bump it for every
  rebuild with changes, as apt won't replace a package with a different one
  of the same version.
- **Special builds:**
  - libpve-rs-perl is built in `~/proxmox-devuan/build/libpve-rs-perl-<version>/`
    with a generated `.cargo/config.toml` (the local crates patched in) and
    `dpkg-buildpackage -d`.
  - pve-lxc-syscalld is built from its build directory moved to
    `~/proxmox-devuan/build/` (its own `.cargo` config points at Debian's crate
    registry), without `.cargo`, without the `prepare-debian` line in
    `debian/rules`, and with `-d`.
- **Building** (`repo/build-repo.sh <dir>`):
  - reads the profile name from `debian/rules`
  - sets `DEB_BUILD_PROFILES="nocheck pkg.<src>.lsbservice"` (without
    `nocheck` if `WITH_TESTS=1`), and `parallel=$BUILD_PARALLEL`
  - installs build dependencies:
    - normally via `mk-build-deps` with the profiles
    - with `RELAX_BUILD_DEPS=1`, one by one, skipping `dpkg-checkbuilddeps`
      (for circular build dependencies)
  - runs `make clean` (stale build directories would hide source changes;
    seen with lxc), then `make deb`
  - copies the debs into the repo; logs to `~/proxmox-devuan/build-logs/<repo>.log`
    with `tee -a`

## Build order

Each package is built after its build dependencies are installed.

1. Fetch from Proxmox (all packages without changes for Devuan,
   `openrc-devuan.md`, step 82): libpve-access-control,
   libpve-guest-common-perl, librados2-perl, the Ceph 19 libraries,
   pve-edk2-firmware-*, proxmox-backup-client, proxmox-backup-file-restore,
   libproxmox-backup-qemu0, proxmox-websocket-tunnel, pve-xtermjs,
   proxmox-termproxy, proxmox-widget-toolkit, pve-yew-mobile-gui,
   pve-i18n, pve-yew-mobile-i18n, pve-docs, pve-doc-generator,
   proxmox-mail-forward, proxmox-enterprise-support-keyring,
   proxmox-firewall-data, proxmox-frr-templates, zfsutils-linux and libs,
   proxmox-biome, and libpve-apiclient-perl, libpve-http-server-perl,
   spiceterm, vncterm, libjs-extjs, fonts-font-logos, libjs-qrcodejs,
   novnc-pve, perlmod-bin, libproxmox-acme-perl, libproxmox-acme-plugins,
   libproxmox-rs-perl, kronosnet (libknet, libnozzle) for corosync, and
   swtpm (swtpm, swtpm-libs, swtpm-tools, libtpms0) for qemu-server.
2. **proxmox-perl-rs** → libpve-rs-perl, first and without its tests
   (`nocheck`): pve-common's build needs Proxmox's libproxmox-rs-perl,
   which depends on libpve-rs-perl. libpve-rs-perl's build itself needs
   libproxmox-rs-perl only for its tests, so with `nocheck` it needs no
   package from that cycle; pve-common's build then installs both. It's built against the changed proxmox-rs crates
   (needs perlmod-bin). `pve-rs/.cargo/config.toml` restricts cargo
   to Debian-packaged crates (`/usr/share/cargo/registry`), which Devuan
   doesn't have all of. So it's built in a copy outside the repository
   (`build/libpve-rs-perl-<version>/`, made by the package's `make
   libpve-rs-perl-<version>`), whose `.cargo/config.toml` is replaced by a
   `[patch.crates-io]` section pointing the crates of the local proxmox-rs,
   proxmox-ve-rs and perlmod at their directories (the other crates come
   from crates.io), and whose `debian/rules` doesn't set up the Debian
   registry. The repository stays unchanged.
3. **pve-common** (lsbservice) → libpve-common-perl.
4. **pve-qemu** → pve-qemu-kvm (stderr patch), based on 11.1.3-1,
   then **corosync-pve** (`pkg.corosync.lsbservice`), whose libraries
   pve-cluster builds against.
5. **pve-cluster**, with `WITH_TESTS=1 BUILD_PARALLEL=1`:
   - The `check` target generates `IPCC.so`/`IPCConst.pm`, and a parallel
     build races on `PVE::IPCC`.
   - `perl -T` ignores `PERL5LIB`, so libpve-access-control (which depends
     on pve-cluster) is bootstrap-installed first with
     `dpkg -i --force-depends`.
6. **pve-storage**, then **pve-firewall** and **pve-network**. They depend
   on each other: bootstrap-install one with `--force-depends`, build the
   other, then reinstall both cleanly with apt.
7. **ifupdown2** (needed once libpve-network-perl is installed),
   **frr** (`pkg.frr.lsbservice`) and **ksm-control-daemon**
   (`pkg.ksm-control-daemon.lsbservice`).
8. **pve-ha-manager**, **lxc**, **pve-lxc-syscalld**. Build
   pve-lxc-syscalld outside the repository tree (`~/proxmox-devuan/build/`),
   because cargo picks up `.cargo/config.toml` from parent directories.
9. **pve-container**, **qemu-server**.
10. **pve-manager** (`RELAX_BUILD_DEPS=1 BUILD_PARALLEL=1`; needs fakeroot
    and proxmox-biome).
11. **proxmox-firewall** (`pkg.proxmox-firewall.lsbservice`), built like
    libpve-rs-perl against the local crates.
12. **proxmox-kernel-helper** (`pkg.proxmox-kernel-helper.lsbservice`) and
    **proxmox-ve** (`pkg.proxmox-ve.lsbservice`), after downloading
    Proxmox's kernel.

## Building with GitHub Actions

The workflow `.github/workflows/build-repo.yml` in this repository
(`psakar/proxmox-devuan`), started by hand (Actions → Build repository → Run
workflow), builds incrementally and publishes the repository as a release
`<date>-<time>` in UTC (e.g. `20261012-0856`) with `proxmox-devuan-repo-<tag>.tar.gz`
and its signature `.tar.gz.asc`.

- **What gets built** (input `steps`):
  - `auto` (default): the steps whose source repositories' commits differ
    from the last release's `SOURCES`, that it doesn't list, or whose
    recorded version isn't in the repository's `Packages`, plus
    `proxmox-default-kernel` and `proxmox-secure-boot-support` (Proxmox's
    current kernel and Secure Boot packages, downloaded). Which
    repositories a step is built from: `build.sh --sources <step>` (e.g.
    libpve-rs-perl also from proxmox-rs, proxmox-ve-rs and perlmod).
    Clones follow the forks' feature branch or Proxmox's master, except
    where `REF` in `prepare-build.sh` pins a commit, tag or branch:
    perlmod and proxmox-ve-rs are pinned, so upstream commits there don't
    rebuild libpve-rs-perl with an unchanged version.
  - `all`, or step names, comma-separated (e.g. `pve-common,qemu-server`).
  - Dependent packages aren't rebuilt: the Perl packages don't need it, and
    the C libraries built here (corosync's, lxc's) keep their ABI within a
    version.
  - Bump the changelog with each change (`+devuan<N>`): a rebuild with an
    unchanged version gets a warning, apt wouldn't upgrade to it.
- **How:** the `build` job restores the last release's tarball into `repo/`
  (after checking its signature against `keys/proxmox-devuan-repo.asc`; input
  `fresh` starts from an empty one instead), then runs
  `ci/build-in-container.sh` in `devuan/devuan:excalibur`: a build user with
  passwordless sudo (like the build machine's `test`), `prepare-build.sh`,
  `select-steps.sh`, `build.sh --only <steps>`, the record in
  `repo/SOURCES`, and `package-repo.sh --prune`. The `release` job, in the
  GitHub environment `release` (the only one with the signing key), signs
  and packs `repo/` and creates the release, with the built steps and
  `SOURCES` in its notes. Neither the packages nor `SOURCES` changed (e.g.
  `auto` without changes and no newer kernel): no release. A rebuild with
  identical packages but new commits still makes one, for its `SOURCES`.
  Build logs: the run's artifact
  `build-logs`.
- **Limits:** a hosted runner (4 CPUs) may run a job for 6 hours at most. A
  build of everything (the first run, `all`, or `fresh`) may exceed that
  with pve-qemu; the release can instead be started from the build
  machine's `repo/`, see below.

**Trying the container build locally** with podman (rootless), in a
separate directory with the scripts (and, for an incremental build, the
last release's packages in `repo/`):

```
mkdir -p ~/ci-test/repo && cp -a build.sh prepare-build.sh select-steps.sh package-repo.sh ci ~/ci-test/
cd ~/ci-test
podman run --rm --userns=keep-id --user root -v "$PWD:/work:Z" -e STEPS=auto -e BUILD_UID="$(id -u)" \
    docker.io/devuan/devuan:excalibur /work/ci/build-in-container.sh 2>&1 | tee ci.log
```

The result is in `repo/` and `build/ci/` (`steps`, `changed`).

**Signing key.** A signing subkey of your key, so that the primary key stays
off GitHub; apt and `gpgv` verify against the public key:

```
gpg --quick-add-key <primary key fingerprint> ed25519 sign 2y
gpg --list-keys --with-subkey-fingerprints <primary key fingerprint>
# the new subkey: [S], note its fingerprint
gpg --armor --export-secret-subkeys <subkey fingerprint>! > signing-subkey.asc
gpg --armor --export <primary key fingerprint> > keys/proxmox-devuan-repo.asc
```

`keys/proxmox-devuan-repo.asc` is committed. The exported subkey keeps the
key's passphrase. In the repository settings on GitHub, create the
environment `release` (Settings → Environments; required reviewers
optional) with two secrets, then delete the exported file:

```
gh secret set GPG_SIGNING_KEY --env release --repo psakar/proxmox-devuan < signing-subkey.asc
gh secret set GPG_PASSPHRASE --env release --repo psakar/proxmox-devuan
shred -u signing-subkey.asc
```

**The first release from the build machine** (instead of a full build on
GitHub): after `build.sh`, with the key on the build machine. Only on the
machine whose `repo/` holds the builds of the clones' current commits:
`record` takes the versions and commits from the clones, not from the
packages.

```
./select-steps.sh record repo/SOURCES $(./build.sh --list)
./package-repo.sh --prune --sign '<subkey fingerprint>!' --tarball dist/proxmox-devuan-repo-<date>.tar.gz
gh release create <date> dist/* --repo psakar/proxmox-devuan --title <date> --notes 'Built on the build machine'
```

## Installing

Installing Proxmox VE on a Devuan 6 machine from a release: `INSTALL.md`.

On the build machine itself, `build.sh --install` installs pve-manager from
`repo/`. After an interrupted bootstrap (`--force-depends`), clean up first
with `dpkg -r` on the bootstrapped package and an apt reinstall: apt
refuses to install anything while dependencies are broken.

From the build machine (unsigned), instead of a release: its `repo/`,
including `Packages`/`Packages.gz`, as `/srv/proxmox-devuan-repo`
(`INSTALL.md`, step 1). For example, with the build in
`~test/proxmox-devuan` on the build machine:

```
sudo rsync -a test@<build machine>:proxmox-devuan/repo/ /srv/proxmox-devuan-repo/
sudo chown -R _apt:root /srv/proxmox-devuan-repo
```

After adding or removing `.deb` files there, regenerate the index with
`sudo /srv/proxmox-devuan-repo/update-index.sh` (needs `apt-utils`), and
run the `chown` again.

Or, on the build machine (with root's SSH access to the install machine),
`update-repo.sh` does both commands:

```
REMOTE_MACHINE=root@<install machine> ./update-repo.sh --rsync
```

`repo/` is unsigned: in its sources entry (`INSTALL.md`, step 2), replace
`Signed-By: …` by `Trusted: yes` (apt 3 then notes "Missing Signed-By",
harmless).

## Updating after a rebuild

From a newer release: download and check it as in `INSTALL.md`, step 1,
replace `/srv/proxmox-devuan-repo`'s content with it, and upgrade:

```
sudo rm -f /srv/proxmox-devuan-repo/*
sudo tar -xzf proxmox-devuan-repo-<tag>.tar.gz -C /srv/proxmox-devuan-repo
sudo chown -R _apt:root /srv/proxmox-devuan-repo
sudo apt update && sudo apt full-upgrade
```

From the build machine, after `build.sh`, copy the new `repo/` and upgrade:

```
REMOTE_MACHINE=root@<install machine> ./update-repo.sh --rsync --upgrade
```

Without `--rsync` it copies with scp, which doesn't remove debs no longer in
`repo/` (harmless: apt reads only the copied `Packages` index); without
`--upgrade` it only copies, and `sudo apt update && sudo apt full-upgrade`
is run on the install machine by hand. When the build adds packages, add
them to the pins (`INSTALL.md`, step 2) first.

## Checking upstream releases

Before rebuilding with Proxmox's newer releases, run from the build
directory (the one with the clones), after `prepare-build.sh`:

```
mkdir -p build-logs
./upstream-tags.sh | tee -a build-logs/upstream-tags.log
./upstream-systemd-scan.sh | tee -a build-logs/upstream-systemd-scan.log
```

Both take their repository list from `prepare-build.sh` (`BUILD_REPOS` and
`SOURCE_REPOS`); repository names as arguments limit them to those clones.

`upstream-tags.sh`:

- fetches Proxmox's repository (remote `upstream`) in each clone
  (`--no-fetch` skips this);
- looks up the latest version of each source package in Proxmox's package
  index (`http://download.proxmox.com/debian/pve`, trixie,
  pve-no-subscription; `PROXMOX_REPO`, `DIST` and `COMPONENT` change them);
- tags the upstream commit that introduced that version in
  `debian/changelog` as `proxmox/<source>/<version>` (DEP-14: `:` becomes
  `%`, `~` becomes `_`). The tags are local only and never pushed; an
  existing tag is kept, with a warning if it points elsewhere. `--dry-run`
  finds the commits without tagging.

It prints one line per source package: the version of the checkout (the
last build), Proxmox's latest version, the tag, and either `included` or
how many upstream commits the checkout lacks. Source packages that aren't
in Proxmox's index (the crates of proxmox-rs and perlmod) are skipped.

`upstream-systemd-scan.sh` scans, for each `proxmox/*` tag not in the
checkout's HEAD, the commits from the merge base to the tag. It reports
each commit that:

- adds or removes lines matching the systemd patterns of
  `systemd-usage-analysis.md` (systemctl, the journal, scopes, sd_notify,
  D-Bus, tmpfiles/sysusers, other systemd tools) or unit file keys;
- changes unit files, tmpfiles/sysusers files, or files with `systemd` in
  their path.

`debian/changelog` and translations are left out; `--lines <n>` limits
the lines shown per commit (default 12). The last line gives the total,
e.g. `9 of 413 commits with systemd-related changes`. The hits need
checking by hand: known false positives are `.scope` in JavaScript,
systemd inside guests (pve-container's `PVE::LXC::Setup`) and
systemd-boot. The relevant ones need the same adaptation as the existing
changes (`openrc-devuan.md`) before the Devuan branches are rebased onto
or merged with the new releases.
