# Proxmox repositories relevant to PVE on Devuan (OpenRC)

The repositories under `~/proxmox` and `~/proxmox/deps` that
matter for installing and running pve-manager on Devuan 6 "excalibur" with
OpenRC. All are clones of `https://git.proxmox.com/git/<name>.git`, with that
remote named `upstream` in the top-level repositories (except proxmox-rs:
`https://github.com/proxmox/proxmox-rs.git`, which is `proxmox.git` on
git.proxmox.com). The repositories with Devuan changes (section 1, and
proxmox-perl-rs) also have remote `origin`, their GitHub fork
`git@github.com:psakar/<name>.git`, whose `feature/init-systems-refactoring`
branch the local one tracks (ifupdown2's, frr's, proxmox-kernel-helper's and
proxmox-ve's aren't forks: Proxmox has no GitHub mirror of them).
"Branch" means `feature/init-systems-refactoring`.
The repositories changed for Devuan (including packaging-only ones with init-system changes (actual or planned)) are at the top level of `~/proxmox`,
as are those with open plan items (including Ceph and ZFS, out of scope for
now). `deps/` holds the unchanged repositories of installed packages and
two kept for reference (sections 3 and 4).

Only packages with changes for Devuan are built here (section 1, plus
libpve-rs-perl in section 2); everything else comes from Proxmox's
repository. Every package built here has a local version,
`<Proxmox's version>+devuan<N>`, e.g. pve-manager `9.2.21+devuan2`, so that
it's told apart from Proxmox's package of the same version and preferred by
apt; `<N>` goes up with each rebuild with changes. libpve-common-perl is
`9.2.3+devuan1` (9.2.3 isn't a Proxmox release).

Scope: PVE **without Ceph and without ZFS**. Their packages are listed
where they're installed as dependencies, but their init-system integration
is out of scope in this initial phase.

## Packaging-only repositories

These repositories hold no source code of their own, only the Debian
packaging (`debian/`, `Makefile`, Proxmox patches) around an upstream
project. Init-system changes in them are packaging changes (init scripts,
`debian/rules`, patches). Those with such changes, done or planned, are at
the top level of `~/proxmox`; the others are in `deps/`.

| Repository | Location | Upstream source | Init-system changes | In section |
|---|---|---|---|---|
| lxc | `~/proxmox/lxc` | submodule `lxc` (mirror_lxc) | done: init scripts | 1 |
| ifupdown2 | `~/proxmox/ifupdown2` | submodule `ifupdown2` (mirror_ifupdown2) | done: init script, start-networking patch | 1 |
| pve-qemu | `~/proxmox/pve-qemu` | submodule `qemu` (mirror_qemu), patches | done: stderr syslog fallback patch | 1 |
| frr | `~/proxmox/frr` | submodule `frr` (mirror_frr) | done: init script, profile | 1 |
| corosync-pve | `~/proxmox/corosync-pve` | submodule `upstream` (mirror_corosync) | done: init script, profile | 1 |
| ksm-control-daemon | `~/proxmox/ksm-control-daemon` | tarball `ksm-control-scripts.org.tar.gz` | done: init script, profile | 1 |
| proxmox-ve | `~/proxmox/proxmox-ve` | none: meta package, only `debian/` | done: profile dropping `systemd-sysv` | 1 |
| zfsonlinux | `~/proxmox/zfsonlinux` | submodule `upstream` (mirror_zfs) | planned, but out of scope | 3 |
| ceph | `~/proxmox/ceph` | vendored tree `ceph/`, patches | planned, but out of scope | 3 |
| novnc-pve | `~/proxmox/deps/novnc-pve` | submodule `novnc` (mirror_novnc) | none | 3 |
| extjs | `~/proxmox/deps/extjs` | vendored tree `extjs/` | none | 3 |
| libjs-qrcodejs | `~/proxmox/deps/libjs-qrcodejs` | vendored `src/qrcode.js` | none | 3 |
| fonts-font-logos | `~/proxmox/deps/fonts-font-logos` | vendored `src/font-logos/` | none | 3 |
| pve-edk2-firmware | `~/proxmox/deps/pve-edk2-firmware` | submodule `edk2` (mirror_edk2) | none | 3 |
| proxmox-biome | `~/proxmox/deps/proxmox-biome` | vendored `biome/`, `vendor/` | none | 3 |
| lxcfs | `~/proxmox/deps/lxcfs` | submodule `lxcfs` (mirror_lxcfs) | none (Devuan's lxcfs used) | 4 |

Mixed, own code plus a bundled upstream: vncterm (LibVNCServer tarball),
proxmox-acme (acme.sh submodule for the DNS plugins), pve-xtermjs (xterm.js
packaging next to its own termproxy), proxmox-backup-qemu (proxmox-backup
submodule). All other repositories listed below are Proxmox's own code.

## 1. Changed for the init system (20)

Packages built from them are installed here: with their `pkg.<source>.lsbservice`
profile where they have one, pve-qemu with a local `+devuan1` version, and
proxmox-rs as the source of the Rust crates compiled into libpve-rs-perl.

| Repository | Path | Source package | Binary packages used | Commits on branch |
|---|---|---|---|---|
| pve-common | `pve-common` | libpve-common-perl | libpve-common-perl | 26 |
| pve-manager | `pve-manager` | pve-manager | pve-manager | 32 |
| pve-cluster | `pve-cluster` | pve-cluster | pve-cluster, libpve-cluster-perl, libpve-cluster-api-perl, libpve-notify-perl | 6 |
| pve-ha-manager | `pve-ha-manager` | pve-ha-manager | pve-ha-manager | 9 |
| qemu-server | `qemu-server` | qemu-server | qemu-server | 11 |
| pve-container | `pve-container` | pve-container | pve-container | 5 |
| pve-storage | `pve-storage` | libpve-storage-perl | libpve-storage-perl | 4 |
| pve-firewall | `pve-firewall` | pve-firewall | pve-firewall | 6 |
| pve-network | `pve-network` | libpve-network-perl | libpve-network-perl, libpve-network-api-perl | 7 |
| pve-lxc-syscalld | `pve-lxc-syscalld` | pve-lxc-syscalld | pve-lxc-syscalld | 2 |
| lxc | `lxc` | lxc-pve | lxc-pve | 4 |
| ifupdown2 | `ifupdown2` | ifupdown2 | ifupdown2 | 3 |
| frr | `frr` | frr | frr, frr-pythontools (and frr-doc, frr-snmp, frr-rpki-rtrlib, frr-test-tools) | 3 |
| corosync-pve | `corosync-pve` | corosync | corosync, libcfg7, libcmap4, libcorosync-common4, libcpg4, libquorum5, libvotequorum8 (and corosync-notifyd, the -dev packages, …) | 3 |
| ksm-control-daemon | `ksm-control-daemon` | ksm-control-daemon | ksm-control-daemon | 2 |
| proxmox-kernel-helper | `proxmox-kernel-helper` | proxmox-kernel-helper | proxmox-kernel-helper | 3 |
| proxmox-ve | `proxmox-ve` | proxmox-ve | proxmox-ve | 2 |
| proxmox-firewall | `proxmox-firewall` | proxmox-firewall | proxmox-firewall (proxmox-firewall-data, from its `proxmox-firewall-data/` directory, stays Proxmox's) | 2 |
| pve-qemu | `pve-qemu` | pve-qemu-kvm | pve-qemu-kvm (11.0.3-4+devuan1); branch from `stable-11.0` at `7fccdcf` | 2 |
| proxmox-rs | `proxmox-rs` | Rust crates (`proxmox-apt`, `proxmox-apt-api-types`, `proxmox-log`, …) | compiled into libpve-rs-perl, see section 2 | 5 |

## 2. Built here without init-system changes in their own code

| Repository | Path | Binary packages |
|---|---|---|
| proxmox-perl-rs | `proxmox-perl-rs` | libpve-rs-perl (`0.15.3+devuan1`): the Perl/Rust bindings are unchanged, but it's built against the changed proxmox-rs crates (section 1), on branch `feature/init-systems-refactoring` (2 commits). Built by `build.sh` in a copy outside the repository with a generated `.cargo/config.toml` (local crates patched in, the rest from crates.io); the repository's own is unchanged. libproxmox-rs-perl from the same repository is Proxmox's (section 3) |

## 3. Installed unchanged from download.proxmox.com

Fetched with signature-checked `Release` files (pve-no-subscription,
ceph-squid, devel) into the local repository `repo-proxmox/`. None has init-system code
affecting PVE, except where noted. The kernel (proxmox-default-kernel,
proxmox-kernel-<series>, the kernel image, pve-firmware; not from these
repositories) is downloaded by `build.sh`'s last step into `repo/` instead.

| Repository | Path | Binary packages | Note |
|---|---|---|---|
| perlmod | `perlmod` | perlmod-bin | from the devel repository; build dependency of libpve-rs-perl |
| proxmox-acme | `proxmox-acme` | libproxmox-acme-perl, libproxmox-acme-plugins | |
| proxmox-perl-rs | `proxmox-perl-rs` | libproxmox-rs-perl | libpve-rs-perl from the same repository is built here (section 2) |
| pve-apiclient | `deps/pve-apiclient` | libpve-apiclient-perl | |
| kronosnet | not cloned | libknet1t64, libnozzle1t64 (build: libknet-dev, libnozzle-dev) | 1.35 for Proxmox's corosync (needs ≥ 1.32, Devuan has 1.31); pinned to 600 like the Ceph libraries |
| pve-http-server | `deps/pve-http-server` | libpve-http-server-perl | |
| spiceterm | `deps/spiceterm` | spiceterm | |
| vncterm | `deps/vncterm` | vncterm | |
| extjs | `deps/extjs` | libjs-extjs | 7.0.0-7 |
| fonts-font-logos | `deps/fonts-font-logos` | fonts-font-logos | |
| libjs-qrcodejs | `deps/libjs-qrcodejs` | libjs-qrcodejs | |
| novnc-pve | `deps/novnc-pve` | novnc-pve | |
| pve-access-control | `deps/pve-access-control` | libpve-access-control | |
| pve-guest-common | `deps/pve-guest-common` | libpve-guest-common-perl | |
| librados2-perl | `deps/librados2-perl` | librados2-perl | |
| pve-edk2-firmware | `deps/pve-edk2-firmware` | pve-edk2-firmware-ovmf, -legacy | |
| proxmox-backup | `deps/proxmox-backup` | proxmox-backup-client, proxmox-backup-file-restore | the server part is systemd-bound, the client isn't |
| proxmox-backup-qemu | `deps/proxmox-backup-qemu` | libproxmox-backup-qemu0 | |
| proxmox-websocket-tunnel | `deps/proxmox-websocket-tunnel` | proxmox-websocket-tunnel | |
| pve-xtermjs | `deps/pve-xtermjs` | pve-xtermjs, proxmox-termproxy | |
| proxmox-widget-toolkit | `proxmox-widget-toolkit` | proxmox-widget-toolkit | unchanged: its journal view accepts the journal API's plain format, served from the syslog files under LSB |
| ui | `ui` | pve-yew-mobile-gui | unchanged: it has no journal view |
| proxmox-i18n | `deps/proxmox-i18n` | pve-i18n, pve-yew-mobile-i18n | |
| pve-docs | `deps/pve-docs` | pve-docs, pve-doc-generator | |
| proxmox-mail-forward | `deps/proxmox-mail-forward` | proxmox-mail-forward | |
| proxmox-enterprise-support | `deps/proxmox-enterprise-support` | proxmox-enterprise-support-keyring | |
| proxmox-ve-rs | `proxmox-ve-rs` | proxmox-frr-templates | |
| ceph | `ceph` | ceph-common, ceph-fuse, librados2, librbd1, libcephfs2, python3-ceph* … (19.2 libs) | **out of scope**; installed only as library dependencies; Ceph daemons ship systemd units only |
| zfsonlinux | `zfsonlinux` | zfsutils-linux, libzfs7linux, libzpool7linux, libnvpair3linux, libuutil3linux | **out of scope**; installed as dependencies; ships systemd units only, so no ZFS pool import/mount at boot (see `known-issues.md`) |
| proxmox-biome | `deps/proxmox-biome` | proxmox-biome | build dependency of pve-manager only |

## 4. Relevant, with init-system work, not installed yet

| Repository | Path | Why relevant | systemd footprint |
|---|---|---|---|
| pve-vgpu-helper | `pve-vgpu-helper` | `pve-nvidia-vgpu-helper`, recommended by pve-manager | `Depends: systemd`, `pve-nvidia-sriov@.service` |
| proxmox-mini-journalreader | `deps/proxmox-mini-journalreader` | journal API backend; dropped by the lsbservice profile | reads the systemd journal; no replacement needed |
| lxcfs | `deps/lxcfs` | Proxmox's lxcfs build | Devuan's own package (with init script) is used instead |

## Not relevant

Not needed for PVE on Devuan, so left out of the analysis and the plan, and
not cloned locally (clone from `https://git.proxmox.com/git/<name>.git` if
needed):

- **Other products:** pmg-api, pmg-docs, pmg-gui, pmg-log-tracker, pmg-rs,
  proxmox-mailgateway, proxmox-spamassassin, proxmox-backup-meta,
  proxmox-backup-restore-image, proxmox-datacenter-manager,
  proxmox-datacenter-manager-meta, vma-to-pbs, pve-installer, pve-client,
  proxmox-offline-mirror (pve-manager only recommends its
  `proxmox-offline-mirror-helper`, which has no systemd code; not
  installed).
- **Kernel, boot and firmware** (installed by the separate
  `proxmox-default-kernel` install, no init-system code involved):
  pve-kernel, pve-kernel-meta, pve-firmware, grub2, shim-signed,
  efi-boot-shim, proxmox-secure-boot-*, fwupd, fwupd-efi.
- **Toolchains and build helpers:** rustc, cargo, llvm-toolchain,
  wasi-libc, dh-cargo, debcargo-conf, package-rebuilds, proxmox-perltidy,
  pve-eslint, pve-jslint, proxmox-test-tools, proxmox-e2e-tests, flutter,
  framework7, sencha-touch.
- **Upstream mirrors/rebuilds Devuan provides:** systemd, apparmor, lvm,
  iproute2, parted, smartmontools, tar, libgit2, libusb, libiscsi, libqb,
  kronosnet, criu, swtpm, libtpms, usb-redir, qemu, qemu-defaults,
  openvswitch, ovs, ifupdown-pve, corosync-qdevice, glusterfs, dlm,
  gfs2-utils, drbd-utils, fence-agents-pve, resource-agents-pve.
- **Obsolete:** vzctl, vzquota, openais-pve, redhat-cluster-pve, cgmanager,
  pve-sheepdog, pve-libspice-server, pve-spice-protocol, pve-qemu-kvm
  (old repo, now pve-qemu), pve-rs (now in proxmox-perl-rs), pve-omping,
  pve2-api-doc, pve-libseccomp2.4-dev, aab, dab, dab-pve-appliances.
- **Other Proxmox crates/tools not in the PVE closure:** proxmox-acme-rs,
  proxmox-api-types, proxmox-apt, proxmox-fuse, proxmox-openid-rs,
  proxmox-resource-scheduling, pxar, pathpatterns, arch-pacman,
  proxmox-rrd-migration-tool, proxmox-network-interface-pinning,
  proxmox-geojson-data, proxmox-archive-keyring, pve-zsync,
  pve-esxi-import-tools, pve-storage-plugin-examples, libarchive-perl,
  libxdgmime-perl, libpve-u2f-server-perl, libanyevent-http-perl,
  libhttp-daemon-perl, libnet-http-perl, libgtk3-webkit-perl.
