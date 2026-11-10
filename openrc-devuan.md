# Plan: Proxmox VE on Devuan with OpenRC

How to make Proxmox VE work with an init system other than systemd,
specifically Devuan 6 "excalibur" with sysvinit as PID 1 and OpenRC as rc
system. The plan has four parts:

- **Part A** lists, per project, the code changes and the build/packaging
  changes needed, both done and open.
- **Part B** lists every change done so far, in the order it was made, in
  enough detail to redo it.
- **Part C** points to building the result (`BUILD.md`); installing it:
  `INSTALL.md`.
- **Part D** is the testing still to do.

Facts behind it: `systemd-usage-analysis.md`. Repositories: `repositories.md`.
Building: `BUILD.md`. Installation: `INSTALL.md`.
Open problems on the installed system: `known-issues.md`. State: 2026-10-02.

**Scope:** PVE without Ceph and without ZFS.

**Status:** pve-manager 9.2.21 and all its dependencies are installed and
running under OpenRC (12 repositories changed, 69 commits). The OS release
fix in proxmox-rs (4 more commits) is deployed via a rebuilt libpve-rs-perl. VM and container
operations, HA, SDN and a full reboot are not tested yet.

## Design rules

Every change follows these rules. They're also what to apply to the open items
in Part A.

1. **One facade, two backends, chosen at build time.** All init-system
   operations of the Perl code go through `PVE::InitSystem` (pve-common).
   - Its backends `PVE::InitSystem::Systemd` and
     `PVE::InitSystem::LSBService` are selected when building pve-common:
     `PVE_INIT_SYSTEM=systemd|lsbservice` generates
     `PVE/InitSystem/Backend.pm`.
   - Callers never use a backend module, `systemctl` or `journalctl`
     directly.
   - The LSBService backend works through `service(8)`, `update-rc.d` and
     `invoke-rc.d`, which drive both sysv-rc and OpenRC, and through raw
     cgroup v2 for scopes.
2. **One build profile per source package:** `pkg.<source>.lsbservice`.
   - The default build stays byte-for-byte what it was.
   - With the profile, `debian/rules` exports `PVE_INIT_SYSTEM=lsbservice`
     to the Makefiles, which then don't install the systemd units.
   - The `systemd` dependency becomes `systemd <!pkg.<source>.lsbservice>`.
   - Build both variants with `dpkg-buildpackage -b [-Ppkg.<source>.lsbservice]`.
3. **Use runtime decisions only where the build can't know the answer.**
   Examples:
   - remote cluster nodes (check `/run/systemd/system`)
   - "does the init system provide service X" (`service_status`), for
     packages from other sources: dnsmasq, frr, zfs-import@
4. **LSB init scripts mirror the units.**
   - Dependency headers reproduce `After=`/`Before=`/`Wants=`, checked with
     `insserv` in dry-run mode.
   - The scripts reproduce the units' side effects: pid files,
     `RuntimeDirectory=`, tmpfiles, `ExecStartPre=`, timeouts, OOM score.
   - Scripts live in `debian/<package>.<name>.init` and are installed by
     `dh_installinit` with the same start/restart options as
     `dh_installsystemd`. pve-manager's are in `services/init.d/`, installed
     by its Makefile and registered by postinst.
5. **PVE daemons started from init scripts are marked.**
   - The init script exports `PVE_INIT_SCRIPT=1` before running
     `<daemon> start|stop|restart`. `PVE::InitSystem::started_by_init()`
     accepts it.
   - Without it, the daemon asks the init system to start it, which runs
     the init script again, recursing endlessly.
6. **Init scripts exit with the real status.** `log_action_end_msg` doesn't
   return its argument, so keep `status=$?`, print it, then `exit $status`.
7. **Pass lintian.**
   - Add `debian/<package>.lintian-overrides.lsbservice`, installed only with
     the profile, overriding `missing-systemd-service-for-init.d-script`
     (lintian errors fail Proxmox's `make deb`).
   - Add `${misc:Pre-Depends}` to the package, which carries the
     init-system-helpers version needed for `invoke-rc.d --skip-systemd-native`.
8. **Use versioned dependencies on the facade.** Packages using new
   `PVE::InitSystem` functions or the `PVE_INIT_SCRIPT` marker depend on
   `libpve-common-perl (>= 9.2.3)`, a local version bump.
9. **Commit each step separately.** Fixes go in their own commit with a
   `Fixes:` trailer. Branch `feature/init-systems-refactoring` in every
   repository.

## Part A: changes per project

For each project: the **code** changes (program logic: Perl, C, Rust, JS)
and the **build/packaging** changes (Makefiles, `debian/`, init scripts,
cron and logrotate files), done (✔, with the step number from Part B) and
open (✘). Init scripts count as packaging. They replace units and are
installed by the packaging.

### pve-common (libpve-common-perl)

Code:

- ✔ `PVE::InitSystem` facade with fixed interface; `PVE::InitSystem::Systemd`
  backend from `PVE::Systemd`; `PVE::Systemd` and `PVE::Daemon` delegate to
  the facade (1, 2).
- ✔ `PVE::InitSystem::LSBService` backend:
  - service control via `service(8)`, timezone without timedatectl, and
    scopes as cgroup v2 directories (4, 6)
  - controller delegation, property validation before use, and timezone
    read from `/etc/localtime` (8)
- ✔ Service state, reload, try-reload-or-restart, enable/disable, main PID,
  and `dump_syslog`; `PVE::Tools::dump_journal` becomes a wrapper (9).
- ✔ `read_journal`: the journal API from the rsyslog files, for the web
  UI's system and service logs (85).
- ✔ `started_by_init()` with the `PVE_INIT_SCRIPT` marker, used by
  `PVE::Daemon` (14).
- ✔ `PVE::Systemd::systemd_call` restored (31); prototype fix in the
  `wait_for_unit_removed`/`is_unit_active` wrappers (35).
- ✔ Scopes in the requested slice (33), `set_scope_properties` (34),
  `stop_scope` and `reset_failed` (38).
- ✔ Mount management: `create_mount`, `get_mount`, `list_mounts`,
  `remove_mount`, `mount_runtime` (45).
- ✔ Template instances `name@inst` (51); `force-reload` fallback (59).
- ✔ Tests: `test/initsystem-test.pl` (9 and later).
- ✔ Taint safety: the API daemons run with `perl -T`. Untaint where it's
  read from the system (76):
  - scope paths from `glob()` (`find_scope_path`: only below the cgroup
    base, slice names as `slice_dirs()` allows)
  - PIDs from `cgroup.procs` (`stop_scope`)
  - instance marker names (`instance_markers`)

  Before, VM start via the API failed with "Insecure dependency in rmdir
  while running with -T switch" once the VM had run before. New test
  `test/initsystem-taint-test.pl` runs under `perl -T`.
- ✘ Optional: a foreground mode for `PVE::Daemon` without debug output, for
  OpenRC's `supervise-daemon`.

Build/packaging:

- ✔ `src/Makefile` generates `PVE/InitSystem/Backend.pm` from
  `PVE_INIT_SYSTEM` (`FORCE` prerequisite; `.gitignore`) (3, 7).
- ✔ `pkg.pve-common.lsbservice` profile in `debian/rules`;
  `libnet-dbus-perl` only without it (3, 5, 7).
- ✔ Version 9.2.3 (25).
- ✔ `pve-service-instances` init script and lintian override, installed only
  with the profile (51).
- ✔ `pve-machine-id` init script
  (`debian/libpve-common-perl.pve-machine-id.init`):
  - Header: rcS, `Required-Start: $remote_fs`, `X-Start-Before: dbus`.
  - Creates `/etc/machine-id` if it's missing or empty: from a valid
    `/var/lib/dbus/machine-id`, else from `/dev/urandom` (coreutils only,
    no dbus dependency). Written atomically with mode 0444.
  - Symlinks `/var/lib/dbus/machine-id` to it if D-Bus has none yet.
  - Never changes an existing ID.
  - Installed by `dh_installinit --name pve-machine-id --no-stop-on-upgrade`
    with the profile only, so it also runs on installation.
  - Packaging: lintian override `missing-systemd-service-for-init.d-rcS-script`,
    `Pre-Depends: ${misc:Pre-Depends}` (74).
- ✘ The version is local; it needs a real one agreed with upstream.

### pve-manager

Code:

- ✔ Services API, certificate/ACME reload, `pveupdate`, `pveceph`, the
  syslog, journal and time APIs all go through `PVE::InitSystem` (13).
  Without mini-journalreader, the journal API reads the syslog files via
  `PVE::InitSystem::read_journal` (85); it returned 501 before, and the
  web UI's node "System Log" and service logs stayed empty.
- ✔ `test/check-init-system-calls.sh` in `make check` (13).
- ✔ NIC name pinning: `pve-network-interface-pinning generate` refuses
  without systemd as init (95). It writes systemd `.link` files, which eudev
  ignores, and rewrites `/etc/network/interfaces.new` and the SDN
  configuration to the new names, so the node would have no network after
  the reboot. Not needed on Devuan: the reason for the tool, systemd's
  changing naming schemes, doesn't apply to eudev's kernel names.
  - Optional, not planned: pinning through udev rules
    (`/etc/udev/rules.d/50-pve-<iface>.rules`, `NAME=`), and the same for
    `configs/virtual-function-pinning-helper` (which only acts on pinned
    interfaces). Its udev rule assigns no empty name any more (100).
- ✔ `pveceph install` (also run by the web UI's Ceph wizard) refuses
  without systemd as init: Ceph is out of scope, its packages only ship
  units (92).
- Not needed: `pve8to9`.

Build/packaging:

- ✔ `pkg.pve-manager.lsbservice` profile:
  - `debian/rules` and `defines.mk` set and validate `PVE_INIT_SYSTEM`
  - without the profile: `systemd` and `proxmox-mini-journalreader`; with
    it: `cron` and `rsyslog`
  - units installed only for systemd (11)
- ✔ Files for the lsbservice variant (12):
  - init scripts in `services/init.d/`: pvenetcommit, pvebanner,
    pvedaemon, pveproxy, spiceproxy, pvestatd, pvescheduler, pve-guests,
    pve-sdn-commit, pve-firewall-commit
  - `/etc/cron.d/pve-daily-update`
  - `pve.logrotate.lsbservice`
  - `configs/` and `services/` Makefiles installing by variant
- ✔ `PVE_INIT_SCRIPT=1` in the daemon scripts (15); exit status of the
  one-shot scripts (64).
- ✔ `postinst`/`postrm` for both variants (16).
- ✔ `libpve-common-perl (>= 9.2.3)` (29).
- ✔ lintian overrides, `${misc:Pre-Depends}`, and `pvebanner` sourcing
  init-functions (56).
- ✔ `proxmox-ve-default.link` (`MACAddressPolicy=none`) is installed for
  systemd only: eudev reads no `.link` files and assigns bridges no MAC
  address, so they keep their ports' anyway (92).
- ✘ Optional: OpenRC-native scripts with `supervise-daemon` for pvedaemon
  and pveproxy (needs pve-common's foreground mode).

### pve-cluster

Code:

- ✔ Cluster create/join and the sshd/pvedaemon/pveproxy reloads use
  `PVE::InitSystem`. pvecm's remote QDevice commands choose systemctl or
  service/update-rc.d on the remote node (22).

Build/packaging:

- ✔ `pkg.pve-cluster.lsbservice`: `systemd` only without it (18).
- ✔ `debian/pve-cluster.init` for pmxcfs via `dh_installinit` (21).
- ✔ `libpve-common-perl (>= 9.2.3)` (26).
- ✔ lintian override (52).

### pve-ha-manager

Code:

- ✔ `PVE/HA/Env/PVE2.pm`: shutdown vs. reboot from the runlevel without
  systemd (24).
- ✔ `watchdog-mux.c`: `sync(2)` fallback for `journalctl --sync` (24).

Build/packaging:

- ✔ `pkg.pve-ha-manager.lsbservice`: `systemd` only without it (19).
- ✔ Init scripts for watchdog-mux, pve-ha-crm and pve-ha-lrm via
  `dh_installinit` with dh_installsystemd's options; postinst trigger
  restarts (23).
- ✔ `libpve-common-perl (>= 9.2.3)` with the profile (27).
- ✔ watchdog-mux logrotate (28).
- ✔ lintian override and `${misc:Pre-Depends}` (54).

### qemu-server

Code:

- ✔ `PVE/QemuServer/CGroup.pm`: CPU limit/weight hotplug via
  `set_scope_properties` (36).
- ✔ `PVE/QemuServer.pm`: leftover scope cleanup via `reset_failed` and
  `stop_scope` (39).
- ✔ `PVE/QemuServer/DBusVMState.pm`: the helper is started directly with its
  own notify socket when there's no `pve-dbus-vmstate@` service (40).
- ✔ `PVE/QemuServer/CPUConfig.pm`: the hint names the service (41).

Build/packaging:

- ✔ `libpve-common-perl (>= 9.2.3)` (36).
- ✔ `pkg.qemu-server.lsbservice` (41):
  - `PVE_INIT_SYSTEM` validated in `src/Makefile`
  - unit installs skipped in the sub-Makefiles
  - init scripts for qmeventd and pve-query-machine-capabilities (the
    latter creates `/run/qemu-server`)
- ✔ lintian override and `${misc:Pre-Depends}` (55); exit status (63).

### pve-container

Code:

- ✔ New `src/pve-container-supervise`. `PVE/LXC.pm` `vm_start` uses the
  `pve-container@` service if it exists, the supervisor otherwise (43).

Build/packaging:

- ✔ The supervisor is installed by `src/Makefile`;
  `libpve-common-perl (>= 9.2.3)` (43).
- ✔ `pkg.pve-container.lsbservice`: no `pve-container@`/`-debug@` units or
  slice, no `dh_installsystemd` (44).
- ✔ Tested (Debian 13 unprivileged container, Part D test 3): start
  (supervisor → `lxc-start -F` → the container's init, in `lxc/<vmid>`),
  `pct stop`, `pct shutdown`, `pct reboot`, reboot and poweroff from within
  (the supervisor restarts the container, or exits), debug start; the
  cgroups `lxc/<vmid>` and `lxc.monitor/<vmid>` are removed on stop.
- ✔ The supervisor runs in its own cgroup,
  `pve.slice/pve-container.slice/<vmid>.scope`, not its caller's (97).

### pve-storage (libpve-storage-perl)

Code:

- ✔ `PVE/API2/Disks/ZFS.pm`: `zfs-import@` only via the facade, and only
  if the service exists (46).
- ✔ `PVE/API2/Disks/Directory.pm`, `PVE/Storage/CephFSPlugin.pm`: mounts
  via the `PVE::InitSystem` mount functions (47).
- ✔ `PVE/Storage/ESXiPlugin.pm`: `reset_failed` and `stop_scope` (48).

Build/packaging:

- ✔ `libpve-common-perl (>= 9.2.3)` (47). No profile needed: there are no
  units.

### pve-firewall

Code:

- ✔ `PVE/Firewall.pm`: pvefw-logger reload via
  `try_reload_or_restart_service` (49).

Build/packaging:

- ✔ `libpve-common-perl (>= 9.2.3)` (49).
- ✔ `pkg.pve-firewall.lsbservice` with init scripts for pve-firewall and
  pvefw-logger; postinst reload via invoke-rc.d (50).
- ✔ lintian override and `${misc:Pre-Depends}` (53).

### pve-network (libpve-network-perl)

Code:

- ✔ `PVE/Network/SDN/Frr.pm`, `Controllers/FaucetPlugin.pm`: frr and faucet
  via the facade (57; the fallback to running frrinit.sh directly without
  an frr service was dropped in 87).
- ✔ `PVE/Network/SDN/Dhcp/Dnsmasq.pm`: `dnsmasq@<zone>` instances via the
  facade (58).
- ✔ frrinit.sh fallback dropped: frr has an init script (see frr), so it's
  enabled, started and restarted through the facade only (87).

Build/packaging:

- ✔ `libpve-common-perl (>= 9.2.3)` (57).
- ✔ `pkg.pve-network.lsbservice`: the `dnsmasq@` drop-in is removed after
  `dh_install` (60, fixed in 66).

### pve-qemu (pve-qemu-kvm), packaging-only

Code: none of our own; QEMU is patched through `debian/patches/`.

Build/packaging:

- ✔ New patch `pve/0051-PVE-fall-back-to-syslog-for-stderr-when-daemonized-w.patch`
  (last in `debian/patches/series`), on top of Proxmox's
  `pve/0032-PVE-redirect-stderr-to-journal-when-daemonized.patch` (75).
  - Problem: Proxmox's patch sends a daemonized QEMU's stderr to the
    journal via `sd_journal_stream_fd()` without checking the result.
    Without journald, `dup2()` fails and QEMU keeps the caller's stderr.
    `run_command` then waits forever for EOF: pvestatd's CPU flag query
    hung (node status `unknown`), and so would VM starts.
  - Fix in `os-posix.c` `os_setup_post()`:
    - if the journal fails, use `syslog_stream_fd("QEMU")`: a pipe whose
      lines a detached QEMU thread (`stderr_syslog_thread`) passes to
      `syslog(LOG_ERR)`, after `openlog("QEMU", LOG_PID | LOG_NDELAY,
      LOG_DAEMON)`
    - if that fails too, `/dev/null` like upstream QEMU
    - the journal or pipe fd is closed after `dup2()`
  - Messages end up in `/var/log/syslog` as `QEMU[<pid>]`, readable via
    the PVE syslog API. No change needed in qemu-server or pvestatd.
  - Based on the 11.1.3-1 release at `ae7733c` (`master`), with version
    `11.1.3-1+devuan1`; first made for `stable-11.0` at `7fccdcf`
    (11.0.3-4), see step 101.
  - Patch written with `git am` of the whole series in a scratch worktree
    of the QEMU submodule, exported with `git format-patch --zero-commit
    --no-signature --start-number 51`. checkpatch only asks for a
    `Signed-off-by`, left to the author.
  - Build: Proxmox's `libproxmox-backup-qemu0-dev`, `librbd-dev` and
    `librados-dev` fetched into the local repo; `meson subprojects download`
    run by hand, because the submodule was initialized outside the
    Makefile; `BUILD_PARALLEL=8`, about 13 minutes.
  - Tested:
    - `kvm … -daemonize 2>&1 | cat` returns at once
    - the SIGTERM message is in syslog as `QEMU[<pid>]`
    - pvestatd publishes the TCG and KVM CPU flags, and the node stays
      online
  - `pve-qemu-kvm` was added to the "never from Proxmox" pin of the private
    fetch configuration.
- ✔ VM start test: VM 100 started, stopped and started again through the
  HTTPS API (pvedaemon, `perl -T`), running in `qemu.slice/100.scope`
  (after step 76).
- No lsbservice profile needed: QEMU links libsystemd (available) and
  ships no units; the fallback is decided at runtime.

### corosync-pve (Proxmox's corosync), packaging-only

Code: none.

Build/packaging:

- ✔ `pkg.corosync.lsbservice` profile, so Proxmox's corosync is used
  instead of Devuan's (88).
  - Devuan's ships a working default `/etc/corosync/corosync.conf`.
    pmxcfs then starts in cluster mode for a fake cluster `debian`/`node1`,
    and the node shows as `unknown` (`known-issues.md`). Proxmox's build
    ships that file only as an example.
  - `debian/corosync.corosync.init`, installed with the profile instead of
    the units, mirrors the unit with Proxmox's patch
    `0002-only-start-corosync.service-if-conf-exists`: without
    `/etc/corosync/corosync.conf` (or with `nocluster`), it exits 0 without
    starting corosync, so it stays enabled at boot and `pvecm
    create`/`add` only start it. corosync-notifyd already had an init
    script in both builds.
  - It needs kronosnet 1.32 or newer, Devuan has 1.31: Proxmox's libknet
    and libnozzle are fetched (build) and pinned to 600 (install).
  - The pins keep corosync and its libraries from Proxmox's repository and
    give the local build priority over Devuan's.
  - ✘ Not tested at runtime yet: a cluster (`pvecm create`), corosync at
    boot and shutdown.
- Alternative (not chosen): pve-cluster's lsbservice postinst sets Devuan's
  unmodified default config aside (detected by its dpkg conffile checksum).

### pve-lxc-syscalld

Code: none needed. `sd_notify` is a no-op without `NOTIFY_SOCKET`.

Build/packaging:

- ✔ `pkg.pve-lxc-syscalld.lsbservice`: `etc/pve-lxc-syscalld.init.in`
  generated by `etc/Makefile`, installed instead of the unit; lintian
  override; `${misc:Pre-Depends}` (61).

### lxc (lxc-pve), packaging-only

Code: none (upstream submodule unchanged).

Build/packaging:

- ✔ `pkg.lxc-pve.lsbservice` with init scripts for lxc, lxc-net and
  lxc-monitord; lintian override; `${misc:Pre-Depends}` (62).
- ✔ `/var/lock/subsys` in the lxc script (68).

### ifupdown2, packaging-only

Code: none (upstream submodule unchanged).

Build/packaging:

- ✔ `pkg.ifupdown2.lsbservice` with the `networking` init script; lintian
  override; `${misc:Pre-Depends}` (67).
- ✔ New patch `debian/patches/pve/0016-start-networking-support-systems-not-booted-with-sys.patch`
  for upstream's `ifupdown2/sbin/start-networking` (78):
  - `system_going_down()`: with systemd, `systemctl list-jobs` as before
    (`grep -E`). Otherwise the target runlevel from `runlevel` (0 or 6), or
    OpenRC's `RC_RUNLEVEL` (`shutdown`/`reboot`) with OpenRC as init. Used
    by `stop` with `SKIP_DOWN_AT_SYSRESET=yes`, the default.
  - `--systemd` (journal logging) only passed when booted with systemd.
  - Version `3.3.0-1+pmx12+devuan1`.
  - Replaces a local edit of the installed script (`rc-status --runlevel`
    = `shutdown` plus `pgrep -f`), saved in
    `/var/backups/start-networking.local-fix`.
- ✘ Verify the shutdown path with a real reboot (Part D).

### proxmox-rs and proxmox-perl-rs (libpve-rs-perl, libproxmox-rs-perl)

Code, OS release recognition (proxmox-rs, branch
`feature/init-systems-refactoring`, steps 70–73):

- Problem: `GET /nodes/{node}/apt/repositories` (Node → Repositories in the
  GUI) and adding a standard repository failed with `proxmox-apt error -
  unknown Debian code name 'excalibur'`.
  - `get_current_release_codename()` took `VERSION_CODENAME` from
    `/etc/os-release` as a Debian codename.
  - Devuan has `ID=devuan`, `ID_LIKE=debian`, `VERSION_CODENAME=excalibur`.
  - `proxmox-apt`'s own `test_get_current_release_codename` failed on
    Devuan too.
- ✔ `proxmox-apt-api-types`: `DebianCodename::from_derivative(id, codename)`
  maps every Devuan release (jessie, ascii, beowulf, chimaera, daedalus,
  excalibur, freia) to its Debian base. `DebianCodename` itself stays
  Debian-only, because Proxmox's repository suites and the standard
  repository table are Debian's (70).
- ✔ `proxmox-apt/src/repositories/release.rs`:
  - on Debian, unchanged
  - on derivatives (`ID` ≠ debian, `ID_LIKE` contains debian): by the
    derivative table, else by the major version in `/etc/debian_version`
    (or its `<codename>/sid` form)
  - parsing moved into a function, with tests (71)
- ✔ `proxmox-apt/src/repositories/file.rs` `check_suites`: derivative
  suites are checked by their Debian base via
  `DebianCodename::from_derivative_suite()`, so `daedalus` on excalibur
  gets the "old suite" warning. Test file `tests/sources.list.d/devuan.list`
  plus its expected copy (72).
  - No change for the security suffix: Devuan's security suite is in the
    main archive (`deb.devuan.org/merged <codename>-security`), and the
    `-security` check only concerns `security.debian.org`.
- ✔ `proxmox-apt/src/repositories/repository.rs`: `devuan.org` hosts get
  origin "Devuan" (73).
- Checked, no change needed:
  - pve-manager `PVE/API2/APT.pm` (passes through to
    `Proxmox::RS::APT::Repositories`; changelogs via `apt-get changelog`)
  - the shipped Proxmox sources (`Suites: trixie`)
  - the proxmox-perl-rs bindings (`common/src/bindings/apt_repositories.rs`)
  - pve-common and the other PVE repositories

Code, logging:

- ✔ proxmox-rs `proxmox-log`: syslog fallback (77). Problem: without
  journald, `system_log_layer()` (formerly `journald_or_stderr_layer()`)
  printed `Unable to open syslog: …` on every start of every PVE daemon and
  CLI tool (through libpve-rs-perl) and logged to stderr, which is lost for
  daemons. Now it's journald, else syslog, else stderr.
  - The syslog part is the new module `proxmox-log/src/syslog_layer.rs`:
    `SyslogMakeWriter`, a `MakeWriter` for a `tracing_subscriber::fmt`
    layer with the same compact format as the stderr fallback.
  - Each line goes as one RFC 3164 datagram to `/dev/log`: facility daemon,
    severity from the event's level (error→err, warn→warning, info→info,
    debug/trace→debug), identifier as tracing-journald uses
    (`basename(argv[0])`), PID, local timestamp. It reconnects once if a
    send fails (syslog daemon restarted).
  - It talks to the socket directly instead of using libc
    `openlog`/`syslog`, whose identifier is process-wide and shared with
    the Perl code's `Sys::Syslog` in the PVE daemons.
  - Unit tests: messages, severity and line splitting against a bound
    socket; missing socket. Checked end to end against rsyslog with a
    throwaway program set up like libpve-rs-perl's logger.
  - Not covered: the rest of `proxmox-rs/init-system-rework.md`, which only
    matters for PBS/PDM.

Build/packaging:

- ✔ proxmox-perl-rs: libpve-rs-perl (which contains the APT bindings)
  rebuilt against the fixed `proxmox-apt` and `proxmox-apt-api-types` and
  installed.
  - `build.sh` builds it in a copy outside the repository
    (`build/libpve-rs-perl-<version>/`), whose `.cargo/config.toml` it
    replaces with a `[patch.crates-io]` section pointing every crate of the
    local proxmox-rs, proxmox-ve-rs and perlmod at its directory, and whose
    `debian/rules` it modifies (default `CARGO_HOME`, no `prepare-debian`).
  - Built with `dpkg-buildpackage -b -us -uc -d`; the `librust-*` build
    dependencies are replaced by crates.io and the local crates.
  - Version `0.15.3+devuan1` (step 79); installing it restarts the daemons
    through the `pve-api-updates` trigger.
- ✔ proxmox-perl-rs: libpve-rs-perl rebuilt again with the fixed
  `proxmox-log` and installed: `pvesh`, `qm`, `pvesubscription` and the
  daemons' init scripts no longer print `Unable to open syslog`.
- ✔ proxmox-perl-rs: no change to the repository for the build. The
  former workaround (`pve-rs/.cargo/config.toml` renamed to
  `config.toml.debian`, so cargo didn't use Debian's crate registry) is gone:
  `build.sh` replaces the `.cargo/config.toml` of its out-of-tree build copy
  only (see above), and the repository's file stays as Proxmox has it.
  - The build needs crates.io access, for the crates Devuan doesn't package
    (at the versions needed).
  - Optional alternative, not planned: package the missing `librust-*`
    crates for Devuan, at the versions Proxmox's crates need, as Proxmox
    does in its own repository. The build could then resolve its build
    dependencies with apt and run offline, as a Debian-policy build with the
    repository's `.cargo/config.toml` (`/usr/share/cargo/registry`). It's
    a large amount of work and keeping the crates current is ongoing work,
    for no change in the resulting package.

### proxmox-widget-toolkit and ui (pve-yew-mobile-gui)

Code: none.

- ✔ Journal views: no change needed. `GET /nodes/{node}/journal` no longer
  returns 501 under LSB; it's served from the syslog files in
  mini-journalreader's plain format (pve-common, pve-manager, step 85).
  - `src/panel/JournalView.js` accepts that format also when it asks for
    `structured` (as Node → System Log does), as its legacy flat-string
    format.
  - pve-yew-mobile-gui has no journal view. proxmox-yew-comp's journal view
    (`journal_view.rs`, not used by PVE) handles the plain format only with
    `structured` off: in structured mode it expects records and would fail
    on the plain lines.

Build/packaging: none.

### frr (Proxmox build), packaging-only

Code: none.

Build/packaging:

- ✔ `pkg.frr.lsbservice`: upstream's `frrinit.sh` installed as
  `/etc/init.d/frr` instead of the units (86).
  - Like the units, it's neither enabled nor started on installation
    (`update-rc.d frr defaults-disabled`); pve-network's SDN enables and
    starts it when needed. Its LSB header starts it after `$network`.
  - As `debian/rules` comes from upstream's tree, the Makefile applies the
    profile when preparing the build directory, so `DEB_BUILD_PROFILES`
    must be set for `make` too (`build-repo.sh` does).
  - frr never had `Depends: systemd`; Devuan's own frr has no init script
    either.

### proxmox-ve (meta), packaging-only

Code: none.

Build/packaging:

- ✔ `systemd-sysv <!pkg.proxmox-ve.lsbservice>` (91), so
  `apt install proxmox-ve` works as on Debian.

### proxmox-kernel-helper

Code: none. `proxmox-boot-tool` calls `udevadm settle`, guards
`systemd-detect-virt` with `command -V`, and needs systemd-boot (`bootctl`)
only for systemd-boot setups.

Build/packaging:

- ✔ `pkg.proxmox-kernel-helper.lsbservice`: drops `Depends: systemd` and
  installs an init script instead of `proxmox-boot-cleanup.service` (90).
  The kernel hooks can't replace it: it runs at boot, unpinning a kernel
  pinned for that boot only (`proxmox-boot-tool kernel pin --next-boot`).
- ✘ Not tested at runtime yet: `kernel pin --next-boot` and the cleanup at
  the following boot.

### ksm-control-daemon, packaging-only

Code: none.

Build/packaging:

- ✔ `pkg.ksm-control-daemon.lsbservice`: drops `Depends: systemd` and
  installs `ksmtuned.init` as `/etc/init.d/ksmtuned` instead of the unit
  (89). Proxmox's `init-script.diff` had already adapted the upstream Red
  Hat-style script to LSB, but nothing installed it.
- ✔ ksmtuned starts at boot.
- ✘ Not tested at runtime yet: KSM starting under memory pressure
  (`/sys/kernel/mm/ksm/run`).

### proxmox-firewall (optional, recommended by pve-manager)

Code: none. The `systemctl` call in `proxmox-firewall/src/firewall.rs`
(reloading pvefw-logger) is commented out upstream. Logging goes through
proxmox-log, whose local build falls back to syslog without journald
(proxmox-rs `4b8d3d2d`), so the daemon is built against the local crates.

Build/packaging:

- ✔ `pkg.proxmox-firewall.lsbservice`: an init script instead of
  `proxmox-firewall.service` (96). Without it, enabling the nftables
  firewall (datacenter/host option `nftables`, tech preview) left the node
  without a firewall: pve-firewall stops managing iptables then, and the
  daemon that takes over never started.
- ✔ Tested: the daemon runs from its init script;
  with the datacenter firewall and the node's `nftables` option enabled,
  pve-firewall clears its iptables rules and `nft list ruleset` shows the
  `inet proxmox-firewall` table with the host rules (e.g. `iifname "eth1"
  accept` in `host-in`).
- ✔ Also tested: its syslog output (through proxmox-log's syslog
  fallback, `PVE_LOG=info`), stop/start through the init script, turning
  the firewall off again (rules removed), and guest rules: a test VM with
  `firewall=1` on its NIC got the `bridge proxmox-firewall-guests` table
  with its own chains (its rule, MAC/ARP spoofing protection).
- ✔ Tested: the daemon starts at boot.

### pve-vgpu-helper (pve-nvidia-vgpu-helper; optional, recommended)

Code: none.

Build/packaging:

- ✘ Profile dropping `Depends: systemd`.
- ✘ Run the `pve-nvidia-sriov@<pci>` instances through a template init
  script, started at boot by `pve-service-instances` (step 51).

### No changes needed

No init-system code or packaging:

- pve-access-control, pve-guest-common, pve-apiclient, pve-http-server
- proxmox-acme, perlmod, librados2-perl, proxmox-ve-rs
- pve-qemu, pve-edk2-firmware, proxmox-backup (client packages),
  proxmox-backup-qemu, proxmox-websocket-tunnel
- pve-xtermjs, spiceterm, vncterm, novnc-pve, extjs, fonts-font-logos,
  libjs-qrcodejs
- proxmox-mail-forward, proxmox-i18n, pve-docs, proxmox-enterprise-support,
  proxmox-biome
- Not built here, Devuan's package used instead: lxcfs (corosync-pve: see
  above)

### Out of scope

- **zfsonlinux** (packaging-only):
  - build/packaging: a profile shipping upstream's
    `/etc/init.d/zfs-{import,mount,share,zed}` (already built, but listed in
    `debian/not-installed`) and the scrub/trim jobs as cron
  - code: none in zfs; pve-storage is done (46)
- **Ceph:**
  - packaging: init scripts for the daemons in the ceph repository
  - code: pve-manager's Ceph management (`PVE/Ceph/Services.pm`,
    `PVE/API2/Ceph/OSD.pm`, `pveceph`, `pve-cephx-rotate-service-keys`)
    through the facade, with template instances and remote init-system
    detection

## Part B: changes done, in order

Notation: **N. repository `hash`: subject.** The base is `master` at the
commit given per repository in the table at the end of this part. Unless noted, every change is
verified the way its commit message says (unit tests, runtime test on
Devuan/OpenRC, `insserv` dry run, dummy package builds with and without the
profile). "Docs" steps only change documentation.

### Phase 1: pve-common facade and LSBService backend

1. **pve-common `53f75b5`: Copy PVE::Systemd to PVE::InitSystem::Systemd.**
   - Copy `src/PVE/Systemd.pm` to `src/PVE/InitSystem/Systemd.pm` and change
     only the package name.
   - Add it to `src/Makefile`'s install and check lists.
2. **pve-common `007a738`: Extract PVE::InitSystem facade; update
   PVE::Systemd to delegate.**
   - New `src/PVE/InitSystem.pm` aliases the backend's subs into its
     namespace (fixed `@interface`).
   - The backend gains `start_service`/`stop_service`/`restart_service`
     (wrapping `systemctl`, restart with optional reload).
   - It loses `escape_unit`, `unescape_unit`, `read_ini`, `write_ini` and
     `notify`, which stay in `PVE::Systemd` only.
   - `PVE::Systemd` becomes a compatibility wrapper. `enter_systemd_scope`,
     `wait_for_unit_removed`, `is_unit_active`, `get_timezone`,
     `set_timezone` and `list_timezones` delegate to `PVE::InitSystem`.
   - `PVE::Daemon`'s start/stop/restart handlers use the facade instead of
     `systemctl`.
   - This commit introduced two regressions, fixed in steps 31 and 35.
3. **pve-common `34dd4f6`: Add build-time/build-profile wiring for the
   PVE::InitSystem backend.**
   - `src/Makefile` generates `src/PVE/InitSystem/Backend.pm` from
     `Backend.pm.in` with `PVE_INIT_SYSTEM` (default `systemd`). It needs a
     `FORCE` prerequisite, because the content depends on a variable, not
     on the `.in` file's mtime. The generated file is git-ignored.
   - `PVE::InitSystem` `require`s the backend named there.
   - `debian/rules` sets `PVE_INIT_SYSTEM` from `DEB_BUILD_PROFILES` and
     exports it.
   - `debian/control` makes `libnet-dbus-perl` conditional on the profile, in
     `Build-Depends` and `Depends`.
   - The names used in this step (`sysvinit`) are renamed in steps 6 and 7.
4. **pve-common `8c5c26c`: Add the backend (then named `SysVInit`, renamed
   in step 6).**
   - Service control via `service <name> start|stop|restart`. Restart with
     reload falls back to a full restart if reload fails.
   - Timezone via `/etc/timezone`, the `/etc/localtime` symlink and
     `/usr/share/zoneinfo`. The zone list keeps only files with the TZif
     magic.
   - Scopes (`enter_systemd_scope`, `wait_for_unit_removed`,
     `is_unit_active`) are cgroup v2 directories under `pve.slice`.
     - CPUQuota maps to `cpu.max`, CPUWeight to `cpu.weight`, and CPUShares
       is rejected.
     - KillMode, After, Before, SendSIGKILL and TimeoutStopUSec are ignored.
     - Waiting polls `cgroup.events` for `populated 0`, then removes the
       directory.
5. **pve-common `048192d`: debian: document how to build the sysvinit
   variant for Devuan.** Comments in `debian/rules` and `debian/control`
   with the `dpkg-buildpackage` call.
6. **pve-common `c173507`: Rename PVE::InitSystem::SysVInit to
   PVE::InitSystem::LSBService.** Covers the file, package and Makefile
   mapping. The backend only uses `service(8)` and cgroups, so it isn't
   sysvinit-specific.
7. **pve-common `72cfb84`: Rename the PVE_INIT_SYSTEM value and build
   profile to lsbservice.** The value `sysvinit` becomes `lsbservice` and
   `pkg.pve-common.sysvinit` becomes `pkg.pve-common.lsbservice`, in
   `src/Makefile`, `debian/rules`, `debian/control` and `InitSystem.pm`. The
   old value is rejected with an error.
8. **pve-common `4c60588`: LSBService: fix scope controller delegation,
   option validation and timezone.** These three issues were found on
   Devuan/OpenRC.
   - Enable `cpu io memory pids` in `cgroup.subtree_control` from the root
     down through `pve.slice` before creating a scope.
   - Validate the properties before creating the scope and moving the
     caller into it.
   - `get_timezone` reads the `/etc/localtime` symlink first (trixie has no
     `/etc/timezone`). `set_timezone` updates `/etc/timezone` only where it
     exists.
9. **pve-common `8c1ce4f`: InitSystem: add service state, enable/disable and
   syslog access.**
   - Adds `reload_service`, `try_reload_or_restart_service`,
     `enable_service`/`disable_service` (option `runtime`), `service_status`
     and `service_main_pid`.
     - `service_status` returns description, load, unit, active and sub
       state, type and result.
   - Adds `dump_syslog`, in `dump_logfile`'s format.
   - Systemd backend: `systemctl show`, `systemctl`, and `journalctl` (moved
     from `PVE::Tools::dump_journal`, which stays as a wrapper).
   - LSBService backend:
     - state from the LSB `status` exit code, description from the
       `Short-Description:` header
     - enabled state from `/etc/rc[2-5].d/S??name` links or OpenRC runlevels
     - main PID from the script's pid file or the conventional locations
     - `dump_syslog` parses `/var/log/syslog*` (RFC 3339 and traditional
       timestamps), filtered by tag and since/until
     - aliases `sshd`, `syslog` and `postfix@-` are mapped
   - New `test/initsystem-test.pl`, with mocked commands for both backends.

### Phase 2: pve-manager

10. **pve-manager `e62092ea`: Add init-system analysis and rework plan.**
    Docs: `systemd-usage-analysis.md`, `init-system-rework.md`.
11. **pve-manager `ea2dbc12`: Add pkg.pve-manager.lsbservice build profile.**
    - `debian/rules` sets `PVE_INIT_SYSTEM` from the profile; `defines.mk`
      validates it.
    - `debian/control`: `systemd` and `proxmox-mini-journalreader` only
      without the profile; `cron` and `rsyslog` with it.
    - `services/Makefile` installs the units only for `systemd`.
12. **pve-manager `077342f1`: services: add LSB init scripts and cron job
    for the lsbservice variant.**
    - Init scripts in `services/init.d/`:
      - `pvenetcommit`: rcS, after `$local_fs`, `X-Start-Before: networking`.
      - `pvedaemon`, `pveproxy`, `spiceproxy`, `pvestatd`, `pvescheduler`
        wrap `<daemon> start|stop|restart`; reload is a graceful restart.
        `pveproxy` runs `pvecm updatecerts --silent` before start and
        `pveupdate` if `/var/log/pveam.log` is missing. The storage targets
        become `Should-Start`.
      - `pve-guests`: startall at boot (`pve-startall-delay`), `vzdump -stop`
        plus stopall at shutdown. `stop` only acts in runlevel 0/6
        (`RefuseManualStop=`); `force-stop` bypasses that.
      - `pvebanner`, `pve-sdn-commit`, `pve-firewall-commit` are one-shot.
    - `/run/pve` (0750 root:www-data) is created by the pvedaemon, pveproxy
      and pvestatd scripts.
    - `services/pve-daily-update.cron` installs as
      `/etc/cron.d/pve-daily-update`: `pveupdate` at 1:00 plus a random
      delay of up to 5 h.
    - `configs/pve.logrotate.lsbservice` reloads the proxies via `service`.
    - `configs/Makefile` and `services/Makefile` install by variant.
13. **pve-manager `d5b66cba`: use PVE::InitSystem instead of calling
    systemctl/journalctl directly.** Depends on step 9.
    - `PVE/API2/Services.pm`: `service_status` and the facade start, stop,
      restart, reload and try-reload-or-restart. Services without a
      description are filtered out.
    - `Certificates.pm`, `ACME.pm`, `bin/pveupdate`: reload pveproxy via
      `restart_service('pveproxy', 1)`.
    - `PVE/CLI/pveceph.pm`: `try_reload_or_restart_service`.
    - `PVE/API2/Nodes.pm`:
      - syslog via `dump_syslog`
      - journal API returns 501 if `mini-journalreader` is missing
      - time API via the `PVE::InitSystem` timezone functions
    - `test/check-init-system-calls.sh` runs from `make check` and fails on
      `systemctl`/`journalctl`/`mini-journalreader` in `PVE/` and `bin/`
      outside an allow-list (Ceph, pve8to9).
14. **pve-common `11072af`: Daemon: recognize daemon commands run from LSB
    init scripts.**
    - `PVE::InitSystem::started_by_init()`: Systemd checks parent == PID 1;
      LSBService also accepts `PVE_INIT_SCRIPT=1` and deletes it from
      `%ENV`.
    - `PVE::Daemon` uses `started_by_init()` instead of its own `getppid`
      check.
15. **pve-manager `8d412e4a`: services: mark daemon commands run from the
    LSB init scripts.** `export PVE_INIT_SCRIPT=1` in the pvedaemon,
    pveproxy, pvescheduler, pvestatd and spiceproxy scripts.
16. **pve-manager `89ffece5`: debian: handle the lsbservice variant in the
    maintainer scripts.**
    - `postinst` tells the variants apart by whether the units are
      installed. For lsbservice:
      - `update-rc.d <script> defaults`
      - `invoke-rc.d … start` on install, `reload` on upgrade
      - on the `pve-api-updates` trigger, reload running daemons only
      - create `/run/pve` without systemd-tmpfiles
      - skip the `ceph-crash` restart
    - `postrm`: `update-rc.d … remove` on purge unless systemd is running.
    - The systemd variant runs exactly the same commands as before.
17. **pve-manager `0de19b16`: Add Devuan dependency closure and init-system
    footprint.** Docs: `devuan-dependencies.md`.

### Phase 3: pve-cluster and pve-ha-manager

18. **pve-cluster `9bf237a`: d/control: add pkg.pve-cluster.lsbservice
    build profile dropping systemd.** `systemd <!pkg.pve-cluster.lsbservice>`;
    `debian/rules` detects the profile.
19. **pve-ha-manager `36c292f`: d/control: add pkg.pve-ha-manager.lsbservice
    build profile dropping systemd.** Same pattern as step 18.
20. **pve-manager `0a64ce7b`:** Docs: systemd dependency blocker fixed.
21. **pve-cluster `176a7e3`: d/rules: install an LSB init script for pmxcfs
    with the lsbservice profile.**
    - `debian/pve-cluster.init`:
      - starts after `$network $remote_fs`, before corosync and cron;
        stops after corosync
      - pmxcfs forks and writes `/run/pve-cluster.pid`
      - stop escalates to SIGKILL after 10 s
    - `debian/rules` uses `dh_installinit` with the profile and drops the
      unit.
22. **pve-cluster `ecbaca1`: replace direct systemctl calls with
    init-system agnostic ones.**
    - Cluster create: stop corosync and pve-cluster, then start pve-cluster,
      then corosync.
    - Join: stop pve-cluster, then start pmxcfs and corosync.
    - Reload sshd, pvedaemon and pveproxy via `restart_service(…, 1)`.
    - pvecm QDevice commands on remote nodes: `if [ -d /run/systemd/system ];
      then systemctl …; else service …/update-rc.d …; fi`.
    - Files: `src/PVE/API2/ClusterConfig.pm`, `src/PVE/CLI/pvecm.pm`,
      `src/PVE/Cluster/Setup.pm`.
23. **pve-ha-manager `bccf1cd`: d/rules: install LSB init scripts with the
    lsbservice profile.**
    - `watchdog-mux`:
      - backgrounded, output to `/var/log/watchdog-mux.log`
      - sources `/etc/default/pve-ha-manager`, OOM score -1000
      - not stopped or restarted on upgrades
    - `pve-ha-crm`, `pve-ha-lrm` wrap the daemon commands with
      `PVE_INIT_SCRIPT=1`. Stopping the LRM waits for it to finish.
    - `dh_installinit` gets the same options and order as
      `dh_installsystemd`: LRM restarted before CRM.
    - `postinst`: the `pve-api-updates` trigger restarts the running daemons
      via `invoke-rc.d`.
24. **pve-ha-manager `a0c7c2c`: handle systems not booted with systemd.**
    - `src/PVE/HA/Env/PVE2.pm`: without `/run/systemd/system`, decide
      shutdown vs. reboot from the target runlevel (0/6) instead of
      `systemctl list-jobs`.
    - `src/watchdog-mux.c`: fall back to `sync(2)` if `journalctl --sync`
      can't be run.
25. **pve-common `b935615`: bump version to 9.2.3.** `debian/changelog`.
26. **pve-cluster `17590fe`: d/control: depend on libpve-common-perl with
    PVE::InitSystem.** `libpve-common-perl (>= 9.2.3)` in `Build-Depends`
    and in libpve-cluster-api-perl's `Depends`.
27. **pve-ha-manager `2f870f4`: d/control: lsbservice: depend on
    libpve-common-perl recognizing init scripts.** Versioned
    `libpve-common-perl (>= 9.2.3)` only with the profile.
28. **pve-ha-manager `3431f27`: d/rules: lsbservice: rotate watchdog-mux's
    log file.** `debian/pve-ha-manager.watchdog-mux.logrotate`
    (`copytruncate`), installed only with the profile.
29. **pve-manager `a2253108`: d/control: depend on libpve-common-perl with
    PVE::InitSystem.** `>= 9.2.3`.
30. **pve-manager `1894136a`:** Docs: pve-cluster and pve-ha-manager done.
31. **pve-common `af6e7d7`: Systemd: restore systemd_call for API
    compatibility.**
    - `PVE::Systemd::systemd_call` wraps the Systemd backend's
      implementation. With other backends it dies with a clear error.
    - Fixes step 2, which broke qemu-server's CPU hotplug under systemd too.
32. **pve-manager `df55aa18`:** Docs: systemd_call regression fixed.

### Phase 4: scopes and qemu-server

33. **pve-common `cfababb`: LSBService: create scopes in the requested
    slice.**
    - Honor `Slice=`, nesting with dashes like systemd (`a-b.slice` →
      `a.slice/a-b.slice`); default `pve.slice`.
    - Delegate controllers through every level and reject invalid names.
    - `wait_for_unit_removed` and `is_unit_active` find the scope in any
      slice.
34. **pve-common `b5de93e`: InitSystem: add set_scope_properties.**
    - CPUQuota, CPUWeight and CPUShares on a running scope; undef resets.
    - Systemd: D-Bus `SetUnitProperties` (`CPUQuotaPerSecUSec`, -1 for
      unset, runtime-only).
    - LSBService: write `cpu.max` (default `max`) and `cpu.weight`
      (default 100); CPUShares is rejected.
35. **pve-common `e7b30ff`: Systemd: pass arguments on in the
    wait_for_unit_removed/is_unit_active wrappers.**
    - Call them as `&PVE::InitSystem::…` so the `($;$)` prototype doesn't
      turn `@_` into its count.
    - Fixes step 2 (qemu-server didn't wait for old scopes).
36. **qemu-server `545872a`: cgroup: change a running VM's CPU limit and
    weight via PVE::InitSystem.**
    - `src/PVE/QemuServer/CGroup.pm` uses `set_scope_properties` instead of
      `systemd_call`.
    - `debian/control`: `libpve-common-perl (>= 9.2.3)`.
37. **pve-manager `c055b048`:** Docs.
38. **pve-common `6f414bb`: InitSystem: add stop_scope and reset_failed.**
    - `stop_scope`: with systemd, `systemctl stop`. With LSBService:
      - SIGTERM to the cgroup's processes
      - wait up to the timeout (default 10 s)
      - then `cgroup.kill`/SIGKILL, unless `kill => 0`
      - remove the emptied scope
    - `reset_failed`: with systemd, `systemctl reset-failed` (errors for
      unloaded units ignored); no-op for LSBService.
39. **qemu-server `17a759e`: vm start: clean up a leftover scope via
    PVE::InitSystem.**
    - `src/PVE/QemuServer.pm`: `reset_failed` for the scope and
      `pve-dbus-vmstate@<vmid>`, then `stop_scope` and
      `wait_for_unit_removed`.
    - Errors are ignored as before. LSBService sends SIGTERM only.
40. **qemu-server `0806802`: dbus-vmstate: start the helper directly
    without the systemd service.**
    - `src/PVE/QemuServer/DBusVMState.pm`: if there's no
      `pve-dbus-vmstate@` service, start the helper directly:
      - detached, in its own scope in `qemu.slice`
      - with a `NOTIFY_SOCKET` of ours, waiting for `READY=1`
      - failing at once if it exits before that
    - Stopping is unchanged, via D-Bus `Quit`.
41. **qemu-server `0fdd2f2`: add pkg.qemu-server.lsbservice build profile
    with LSB init scripts.**
    - `debian/rules` sets `PVE_INIT_SYSTEM`, validated in `src/Makefile`.
      The unit installs are skipped in `src/qmeventd/Makefile`,
      `src/query-machine-capabilities/Makefile` and `src/usr/Makefile`.
    - `debian/qemu-server.qmeventd.init`:
      - starts before, stops after, pve-ha-lrm and pve-guests
      - no pid file, so the daemon is found by its executable
    - `debian/qemu-server.pve-query-machine-capabilities.init`:
      - one-shot at boot
      - creates `/run/qemu-server` (root:www-data 0750) and its `efidisk`
        subdirectory
    - `pve-dbus-vmstate@.service` isn't installed; its D-Bus policy is.
    - `CPUConfig.pm`: the missing-capabilities hint names the service.
42. **pve-manager `099ddfca`:** Docs: qemu-server done.

### Phase 5: remaining repositories

43. **pve-container `3697063`: start containers without the systemd
    services where there are none.**
    - New `src/pve-container-supervise`:
      - detaches and returns at once
      - runs `lxc-start -F` (debug options for debug starts)
      - stdout discarded, stderr appended to `/run/pve/ct-<vmid>.stderr`
      - restarts while the post-stop hook leaves the reboot flag, with the
        stop wrapper's sanity checks
    - `src/PVE/LXC.pm` `vm_start`: use `pve-container@` via the facade if
      the service exists, else `pve-container-supervise`.
    - `src/Makefile` installs the script. `debian/control` gets `>= 9.2.3`.
44. **pve-container `ba78f1a`: add pkg.pve-container.lsbservice build
    profile.**
    - `debian/rules` sets `PVE_INIT_SYSTEM`; `src/Makefile` skips the
      `pve-container@`, `pve-container-debug@` and slice units.
    - `dh_installsystemd` is skipped. There are no init scripts to add.
45. **pve-common `86e4060`: InitSystem: add mount management.**
    - New functions: `create_mount`, `get_mount`, `list_mounts`,
      `remove_mount`, `mount_runtime`.
    - Systemd: the exact mount units pve-storage wrote (byte-identical).
    - LSBService: `/etc/fstab` entries marked with a comment (spaces
      escaped, duplicates rejected, file locked); runtime mounts are plain
      `mount`.
46. **pve-storage `0a98c48`: disks: zfs: only touch zfs-import@ units if
    the init system has them.** `src/PVE/API2/Disks/ZFS.pm`: enable/disable
    via the facade, and only if `service_status` shows the service exists.
47. **pve-storage `c9556f4`: manage mounts via PVE::InitSystem.**
    - `src/PVE/API2/Disks/Directory.pm` uses the mount functions; the local
      unit helpers are removed.
    - The index's `unitfile` may point to `/etc/fstab`.
    - `src/PVE/Storage/CephFSPlugin.pm` uses `mount_runtime`.
    - `debian/control` gets `>= 9.2.3`.
48. **pve-storage `9704bf9`: esxi: stop the FUSE mount's scope via
    PVE::InitSystem.** `src/PVE/Storage/ESXiPlugin.pm` uses `reset_failed`
    and `stop_scope`.
49. **pve-firewall `a9faa3d`: firewall: reload pvefw-logger via
    PVE::InitSystem.**
    - `src/PVE/Firewall.pm` uses `try_reload_or_restart_service`.
    - `debian/control` gets `>= 9.2.3`.
50. **pve-firewall `f3fdc85`: add pkg.pve-firewall.lsbservice build profile
    with LSB init scripts.**
    - `debian/pve-firewall.pvefw-logger.init`: early, after `$local_fs`;
      the logger writes its own pid file; stop escalates to SIGKILL after
      5 s.
    - `debian/pve-firewall.pve-firewall.init`:
      - after pve-cluster, `$network` and pvefw-logger
      - switches iptables/ip6tables/ebtables to the legacy alternatives
      - `PVE_INIT_SCRIPT=1`; honors `START_FIREWALL`
    - `postinst`: reload on upgrade via systemd only, or `invoke-rc.d`.
51. **pve-common `683877a`: LSBService: support template service
    instances.**
    - `name@inst` runs `/etc/init.d/name <action> inst` directly, not via
      `service`, so that OpenRC doesn't record the template as started.
      `name@*` stops all instances; `name@` disables all.
    - State is kept in `/var/lib/pve-initsystem/enabled-instances` and
      `/run/pve-initsystem/started-instances`.
    - New `debian/libpve-common-perl.pve-service-instances.init` starts the
      enabled instances at boot and stops the started ones at shutdown.
      It's installed only with the profile and not started on
      install/upgrade.
    - New `debian/libpve-common-perl.lintian-overrides.lsbservice`.
52. **pve-cluster `fa1d281`: d/rules: lsbservice: add lintian override for
    the init script without unit.**
    `debian/pve-cluster.lintian-overrides.lsbservice` (rule 7).
53. **pve-firewall `da5c317`:** lintian override + `${misc:Pre-Depends}`
    (rule 7).
54. **pve-ha-manager `70fb528`:** lintian override + `${misc:Pre-Depends}`.
55. **qemu-server `ec58e7d`:** lintian override + `${misc:Pre-Depends}`.
56. **pve-manager `970115ef`:** lintian override + `${misc:Pre-Depends}`.
    - Also overrides `script-in-etc-init.d-not-registered-via-update-rc.d`,
      because postinst registers the scripts in a loop.
    - `services/init.d/pvebanner` now sources `/lib/lsb/init-functions`.
57. **pve-network `6d8fc74`: sdn: manage frr and faucet via
    PVE::InitSystem.**
    - `src/PVE/Network/SDN/Frr.pm`: enable+start frr unless it's enabled,
      and restart it via the facade.
    - Without an frr service, warn and run `frrinit.sh` directly.
    - `FaucetPlugin.pm`: reload via the facade.
    - `debian/control` gets `>= 9.2.3`.
58. **pve-network `71f11d3`: sdn: dhcp: dnsmasq: manage the instances via
    PVE::InitSystem.** `src/PVE/Network/SDN/Dhcp/Dnsmasq.pm`:
    - reload, enable, restart, stop and disable of `dnsmasq@<zone>`, and
      the D-Bus config reload, via the facade
    - "dnsmasq installed" is checked via `service_status` instead of the
      unit file
59. **pve-common `99f9770`: LSBService: fall back to force-reload for
    scripts without reload.**
    - If `reload` exits 3 (unimplemented), use `force-reload`. Debian's
      dnsmasq script has no reload.
    - Errors include the script's output.
60. **pve-network `aae4068`: add pkg.pve-network.lsbservice build profile.**
    The profile drops the `dnsmasq@` drop-in (ordering after networking);
    this was fixed in step 66.
61. **pve-lxc-syscalld `845e751`: add pkg.pve-lxc-syscalld.lsbservice build
    profile with an LSB init script.**
    - `etc/pve-lxc-syscalld.init.in` is generated like the unit
      (LIBEXECDIR) by `etc/Makefile`. The script:
      - backgrounds the daemon with a pid file
      - starts only once the socket listens
      - creates and removes `/run/pve-lxc-syscalld`
      - starts before and stops after pve-guests
    - `debian/rules` installs it with the profile and drops the unit.
    - Also adds the lintian override, `${misc:Pre-Depends}` and a
      `.gitignore` entry.
62. **lxc `c597683`: add pkg.lxc-pve.lsbservice build profile with LSB init
    scripts.** Upstream's sysvinit scripts don't fit; these mirror the units
    and use the helpers in `/usr/libexec/lxc`:
    - `debian/lxc-pve.lxc.init`: `lxc-apparmor-load`, then
      `lxc-containers start`; creates `/var/lib/lxc`; stamp
      `/run/lxc.started`; reload reloads AppArmor; after lxc-net.
    - `debian/lxc-pve.lxc-net.init`: `lxc-net start|stop`.
    - `debian/lxc-pve.lxc-monitord.init`: backgrounded with a pid file.
    - `debian/rules` drops the units with the profile. Also adds the
      lintian override and `${misc:Pre-Depends}`.
63. **qemu-server `15bd67d`: d/pve-query-machine-capabilities.init: exit
    with the helper's status.** Rule 6.
64. **pve-manager `a711b25c`: services: init.d: exit with the one-shot
    helpers' status.** `pve-firewall-commit`, `pve-sdn-commit` (rule 6).
65. **pve-manager `0d1f0ff7`:** Docs: remaining six repositories done.

### Phase 6: fixes found by the real build and installation

66. **pve-network `ab67a0d`: d/rules: lsbservice: drop the dnsmasq@
    drop-in after dh_install instead.**
    - `src/services/Makefile` installs the drop-in in both variants again
      (`debian/libpve-network-perl.install` lists it).
    - `debian/rules` removes it from the package after `dh_install` with the
      profile.
    - Fixes step 60.
67. **ifupdown2 `98b2f5c`: add pkg.ifupdown2.lsbservice build profile with
    an LSB init script.**
    - Installing pve-network pulls in ifupdown2, which removes ifupdown and
      its init script. Devuan's ifupdown2 has none.
    - `debian/ifupdown2.networking.init`:
      - rcS, `Provides: networking ifupdown`
      - `udevadm settle`, sources `/etc/default/networking`
      - runs `/usr/share/ifupdown2/sbin/start-networking start|stop|reload`
      - not started on install, not stopped on upgrade
    - `debian/rules` drops the units with the profile. Also adds the
      lintian override and `${misc:Pre-Depends}`.
68. **lxc `075dd54`: lsbservice: keep lxc-containers' lock out of liblxc's
    lock directory.**
    - `debian/lxc-pve.lxc.init` runs `install -d -m 0755 /var/lock/subsys`
      before calling `lxc-containers`.
    - Otherwise its fallback lock file `/var/lock/lxc` collides with
      liblxc's directory of that name ("rm: cannot remove … Is a
      directory").
69. **pve-manager `7c30ea4f`:** Docs: real build and installation.

### Phase 7: OS release recognition (proxmox-rs)

Base: proxmox-rs `master` at `89c1d597`. Tests run in a scratch workspace
with only `proxmox-apt` and `proxmox-apt-api-types` as members and
crates.io as registry, because the repository's `.cargo/config.toml`
expects Debian's packaged crates.

70. **proxmox-rs `5bb1c086`: apt-api-types: map Debian derivatives'
    releases to their Debian base.** `DebianCodename::from_derivative(id,
    codename)` with the Devuan table (case-insensitive), plus a unit test.
71. **proxmox-rs `712208b5`: apt: recognize the Debian release Debian
    derivatives are based on.** `proxmox-apt/src/repositories/release.rs`:
    `get_current_release_codename()` reads `/etc/os-release` and
    `/etc/debian_version` and calls the new `parse_release_codename()`.
    That function keeps Debian's behavior, maps derivatives by table, then
    by `debian_version`. Unit tests for Debian, Devuan, an unknown
    derivative release and a non-Debian system.
72. **proxmox-rs `1805b35e`: apt: check the suites of Debian derivatives'
    repositories.**
    - `DebianCodename::from_derivative_suite()` in api-types.
    - `check_suites` in `proxmox-apt/src/repositories/file.rs` falls back
      to it.
    - New `tests/sources.list.d/devuan.list` (excalibur, -security,
      -updates, daedalus, freia) and its writer-normalized copy in
      `tests/sources.list.d.expected/`.
    - New test `test_check_repositories_derivative`.
73. **proxmox-rs `6337ef1a`: apt: report devuan.org repositories' origin
    as Devuan.** `origin_from_uris` in
    `proxmox-apt/src/repositories/repository.rs`; the test expects the
    origins.

### Phase 8: machine ID

74. **pve-common `1865f24`: lsbservice: add a pve-machine-id init script
    creating /etc/machine-id.**
    - New `debian/libpve-common-perl.pve-machine-id.init` (see Part A,
      pve-common).
    - `debian/rules`: second `dh_installinit --name pve-machine-id
      --no-stop-on-upgrade` in the lsbservice `override_dh_installinit`.
    - `debian/control`: `Pre-Depends: ${misc:Pre-Depends}`.
    - Lintian override (rcS tag) and changelog entry.
    - Tested in a sandbox (8 cases); both variants built; installed on
      Devuan, where it's registered in rcS and OpenRC's sysinit runlevel.

### Phase 9: QEMU stderr without journald

75. **pve-qemu `d0d9eab`: add patch falling back to syslog for stderr
    without journald.** Branch `feature/init-systems-refactoring` from
    `stable-11.0` at `7fccdcf` (11.0.3-4); QEMU submodule `aeec49e8`.
    - New `debian/patches/pve/0051-…patch` (see Part A, pve-qemu),
      appended to `series`.
    - Changelog `11.0.3-4+devuan1`.

### Phase 10: taint mode

76. **pve-common `7fbdbc2`: LSBService: untaint what's read from the system
    before acting on it.** `find_scope_path`, `stop_scope`'s `pids` and
    `instance_markers` return only regex-captured, validated values. New
    `test/initsystem-taint-test.pl` (`#!/usr/bin/perl -T`, fake cgroupfs,
    real child processes and init script), added to `test/Makefile`.
    `Fixes:` 8c5c26c, 6f414bb, 683877a. Built with `WITH_TESTS=1`,
    installed, and VM start via the HTTPS API verified.

### Phase 11: Rust logging without journald

77. **proxmox-rs `4b8d3d2d`: log: fall back to syslog if journald isn't
    available.**
    - New `proxmox-log/src/syslog_layer.rs` with unit tests.
    - `lib.rs`: `journald_or_stderr_layer()` renamed to
      `system_log_layer()`, plus the shared `plain_format()`.
    - `builder.rs`: doc comments.
    - libpve-rs-perl rebuilt (`dpkg-buildpackage -b -us -uc -d` in
      `pve-rs/libpve-rs-perl-0.15.3/`) and installed.

### Phase 12: ifupdown2 stop at shutdown

78. **ifupdown2 `24b1e04`: add patch for start-networking on systems not
    booted with systemd.**
    - Patch written on top of the applied series in a scratch worktree of
      the `ifupdown2` submodule and exported with `git format-patch
      --start-number 16`, appended to `series`.
    - Changelog `3.3.0-1+pmx12+devuan1`.
    - Tested: 10 stubbed cases for `system_going_down()`; installed, network
      up, `rc-service networking reload` OK.

### Phase 13: local versions

79. **Local `+devuan1` versions:** one commit per repository whose packages
    are built here, `d/changelog: add a local +devuan1 version for the
    Devuan build`:
    - pve-manager `934229c7`, pve-cluster `d811aef`, pve-ha-manager
      `02aa263`, qemu-server `a0b78b6`, pve-container `56b0c37`, pve-storage
      `facfb38`, pve-firewall `60a8e05`, pve-network `afa2958`,
      pve-lxc-syscalld `f4788a2`, lxc `49f98f1`
    - proxmox-perl-rs `a63ce1e` (libpve-rs-perl; its libproxmox-rs-perl
      part is dropped again in `61a38d4`, as that package comes from
      Proxmox, see step 82)
    - pve-common `ef33937` turns its local `9.2.3` into `9.2.3+devuan1`
    - ifupdown2 and pve-qemu have their `+devuan1` from steps 78 and 75.
    - pve-lxc-syscalld and proxmox-perl-rs (`pve-rs`): the `debian/rules`
      check against `Cargo.toml`'s version ignores a `+devuan` suffix
      (`$(firstword $(subst +devuan, ,$(DEB_VERSION_UPSTREAM)))`).
    - All rebuilt and installed.
80. **Init scripts succeed when starting a running daemon** (LSB): pve-manager
    `cf716c0b` (5 scripts), pve-firewall `6ef89ae`, pve-ha-manager `21c88ba`.
    - These eight scripts wrap a `PVE::Daemon` daemon, whose own `start`
      fails if it's running.
    - Without this, upgrading pve-firewall failed in `invoke-rc.d … start`,
      leaving it and the packages depending on it unconfigured. The other
      init scripts are idempotent already (tested on all running services).
81. **`+devuan2`** for pve-manager (`ec241b78`), pve-firewall (`ee7520d`)
    and pve-ha-manager (`97b6aa0`) with that fix; rebuilt and installed.

### Phase 14: unchanged packages from Proxmox

82. **Packages without changes for Devuan come from Proxmox's repository,
    not from local builds:** libpve-apiclient-perl, libpve-http-server-perl,
    spiceterm, vncterm, libjs-extjs, fonts-font-logos, libjs-qrcodejs,
    novnc-pve, perlmod-bin, libproxmox-acme-perl, libproxmox-acme-plugins
    and libproxmox-rs-perl, like all other unchanged packages (`BUILD.md`).
    - Their repositories have no Devuan branch; the eight in `deps/` stay
      there, perlmod, proxmox-acme and proxmox-perl-rs are at the top level.
    - Where a local build with a higher version is installed, fetch
      Proxmox's version explicitly (`pkg=version`) and install it with
      `--allow-downgrades`. Old local builds are kept in
      `~/proxmox-devuan/repo-removed/`, outside the local repo.

### Phase 15: forks

83. **Absolute submodule URLs:** ifupdown2 `198a6e0`, lxc `43260ae`,
    pve-qemu `f97552a` set their submodule URL in `.gitmodules` to
    `https://git.proxmox.com/git/mirror_<name>` instead of the relative
    `../mirror_<name>`. That only resolves next to Proxmox's own repository,
    not next to the GitHub forks `https://github.com/psakar/<name>`, which
    all changed repositories are pushed to.

### Phase 16: installation on a second machine

84. **pve-guests at boot** (pve-manager `82f95a01`, `+devuan3`): the init
    script runs `pvesh … startall`/`stopall` with stdin from `/dev/null`.
    - OpenRC runs init scripts with the console as stdin, without it being
      their controlling terminal. pve-common's `fork_worker` gives a
      synchronous worker the terminal when stdin is one, and `tcsetpgrp`
      failed with ENOTTY: no guest was started on boot
      (`known-issues.md`). The unit's stdin is `/dev/null`.
85. **Journal API without systemd's journal** (pve-common `cccffb1`,
    `+devuan2`; pve-manager `ef8bd820`, in `+devuan3`):
    - The web UI's node "System Log" and the per-service logs use
      `/nodes/{node}/journal`, which returned 501 without
      mini-journalreader, so both stayed empty.
    - New `PVE::InitSystem::read_journal`: LSBService reads the rsyslog
      files like `dump_syslog` and returns mini-journalreader's plain
      (`-j`) format (first cursor, lines, last cursor), which the
      widget-toolkit's journal view accepts, so the UI is unchanged.
    - A cursor is `rsyslog:<dev>:<inode>:<offset>`, so it survives
      logrotate renaming `syslog` to `syslog.1`; a start cursor in a file
      rotated away means everything is newer, an end cursor there that
      nothing is older.
    - Supported: `lastentries`, `since`/`until`, start/end cursor,
      `service` (identifier), `unit` (as `dump_syslog`), `kernel`.
      Ignored: `priority` (the files don't record it), and the structured
      output (no colouring, empty identifier and unit filter lists).
    - The Systemd backend's `read_journal` dies; pve-manager calls
      mini-journalreader directly there.
    - pve-manager depends on `libpve-common-perl (>= 9.2.3+devuan2)`.
    - Tests: 18 in `test/initsystem-test.pl` (cursors, rotation, filters),
      plus a taint-mode run with a tainted cursor.

### Phase 17: frr

86. **frr: init script** (`e2345a8`, `2fce5d4`, `1be9733`;
    `10.6.1-1+pve3+devuan1`):
    - Absolute URL of the `frr` submodule, as in step 83. Pushed to
      `https://github.com/psakar/frr` (a plain repository with Proxmox's
      `master`, like ifupdown2's).
    - `pkg.frr.lsbservice`: the Makefile, which prepares the build directory
      from upstream's tree and already edits its `debian/rules`, keeps
      `cp build/tools/frrinit.sh debian/frr.init` and drops the units'
      copies instead, and installs the init script with `dh_installinit -r
      --no-enable --no-start` (the units' `--no-enable --no-start`). Plus a
      lintian override for the init script without unit.
    - Built with and without the profile: the default `debian/rules` is
      unchanged; the lsbservice packages have `/etc/init.d/frr`
      (executable, `update-rc.d frr defaults-disabled`, removed on purge)
      and no units, and pass lintian (upstream's warnings only).
    - `build.sh` builds frr after ifupdown2; `prepare-build.sh` clones it
      as a changed repository, and the pins keep `frr` and `frr-*` from
      Proxmox's repository (pve-network recommends frr-pythontools).
    - Not tested at runtime yet: SDN enabling and starting frr.
87. **pve-network `6e9b339`, `4cff062` (`1.6.7+devuan2`): sdn: frr: drop
    the fallback to running frrinit.sh directly.** With the init script
    from step 86, `Frr.pm` enables, starts and restarts frr through
    `PVE::InitSystem` only. Without an frr service, `apply()` now fails in
    `enable_service`, as `systemctl enable --now frr` does, instead of
    warning and running the script.

### Phase 18: corosync

88. **corosync-pve: init script** (`d3a442d`, `09f07c9`, `3b59a8a`;
    `3.1.10-pve3+devuan1`):
    - Absolute URL of the `upstream` submodule, as in step 83.
    - `pkg.corosync.lsbservice` (`debian/rules`): installs
      `debian/corosync.corosync.init` as `/etc/init.d/corosync` with
      `dh_installinit -pcorosync --name=corosync` (enabled, started and
      restarted on upgrades), removes the units of corosync and
      corosync-notifyd after `dh_install`, skips `dh_installsystemd`, and
      adds lintian overrides for both packages.
    - The init script: no start without `/etc/corosync/corosync.conf` or
      with `nocluster` (exit 0, a warning); start waits for corosync's IPC
      (`corosync-cpgtool`, up to `COROSYNC_INIT_TIMEOUT`, like
      `Type=notify`); stop runs `corosync-cfgtool -H --force` first, like
      `ExecStop=`; reads `/etc/default/corosync`.
    - Needs Proxmox's kronosnet (`libknet1t64`, `libknet-dev`,
      `libnozzle1t64`, `libnozzle-dev`, 1.35): fetched by
      `prepare-build.sh` and pinned to 600 like the Ceph libraries, in the
      build's fetch configuration and on the install machines.
    - `build.sh` builds it after pve-qemu, before pve-cluster (which builds
      against its libraries); `prepare-build.sh` clones it as a changed
      repository; the pins keep corosync, `corosync-*` and its libraries
      from Proxmox's repository.
    - Built with and without the profile: the default packages are
      unchanged; the lsbservice ones have `/etc/init.d/corosync` and no
      units, and pass lintian. The script's start conditions were checked
      with stub paths; corosync itself not run yet.
    - Install instructions: the corosync workaround (install it first,
      move its configuration aside, disable it) is gone.

### Phase 19: ksm-control-daemon

89. **ksm-control-daemon: init script** (`c6e8891`, `8ff04a2`;
    `1.5-1+devuan1`):
    - `pkg.ksm-control-daemon.lsbservice` (`debian/rules`,
      `debian/control`): installs the patched `ksmtuned.init` as
      `/etc/init.d/ksmtuned` (`dh_installinit --name=ksmtuned
      --onlyscripts`: enabled, started and restarted on upgrades), skips
      `dh_installsystemd`, drops `Depends: systemd`, and adds a lintian
      override; `${misc:Pre-Depends}` for the init-system-helpers version
      of the `--skip-systemd-native` snippets.
    - `init-script-always-start.diff`: the init script no longer requires
      `START=yes` in `/etc/default/ksmtuned` (policy: disable with
      `update-rc.d`), so `debian/defaults` stays uninstalled.
    - `build.sh` builds it after frr; `prepare-build.sh` clones it as a
      changed repository; the pins keep it from Proxmox's repository.
    - Built with and without the profile: the default package is
      unchanged; the lsbservice one has `/etc/init.d/ksmtuned`, no unit and
      no systemd dependency, and passes lintian (apart from the default
      build's warnings). Not run yet.

### Phase 20: proxmox-kernel-helper and proxmox-ve

90. **proxmox-kernel-helper: init script** (`7c29c12`, `52b99ed`;
    `9.2.0+devuan1`):
    - `pkg.proxmox-kernel-helper.lsbservice` (`debian/rules`,
      `debian/control`): installs
      `debian/proxmox-kernel-helper.proxmox-boot-cleanup.init` as
      `/etc/init.d/proxmox-boot-cleanup` (`dh_installinit
      --name=proxmox-boot-cleanup --no-start`: enabled, not run on
      installation, like the unit's `--no-start`), removes the unit after
      `dh_install`, skips `dh_installsystemd`, drops `Depends: systemd`, and
      adds a lintian override.
    - The init script: a one-shot action at boot (start only; stop does
      nothing). With `/etc/kernel/next-boot-pin`, it runs
      `proxmox-boot-tool kernel unpin --next-boot` and `proxmox-boot-tool
      refresh`, like the unit.
    - Built with and without the profile: the default package is
      unchanged; the lsbservice one has the init script, no unit and no
      systemd dependency, and passes lintian (apart from the default
      build's warning). Not run yet.
91. **proxmox-ve: profile** (`b5073c9`, `7627ce2`; `9.2.0+devuan1`):
    `pkg.proxmox-ve.lsbservice` drops `Depends: systemd-sysv`
    (`debian/control`; `debian/rules` only documents it). Built with and
    without the profile; both pass lintian.
    - `build.sh` builds both after the kernel download;
      `prepare-build.sh` clones them as changed repositories, and the pins
      keep them from Proxmox's repository.
    - Install instructions: `apt install proxmox-ve` instead of
      pve-manager.

### Phase 21: pve-manager leftovers

92. **pve-manager** (`e01fa7f3`, `a0d96545`, `1b1b4e63`; `9.2.21+devuan4`):
    - `configs/Makefile`: the drop-in for systemd's `99-default.link`
      (`proxmox-ve-default.link`, `MACAddressPolicy=none`) only for
      `PVE_INIT_SYSTEM=systemd`. eudev has no `.link` support and doesn't
      set bridge MAC addresses, so the kernel gives bridges their ports'
      address, which is what the drop-in achieves with systemd-udevd.
    - `PVE/CLI/pveceph.pm`: `install` dies unless `/run/systemd/system`
      exists (`sd_booted(3)`'s check), before touching repositories or
      packages. A runtime check: nothing changes on systemd systems.
    - Checked: `configs/` installs the drop-in only for systemd;
      `make check`'s init-system call check passes. Tested: `pveceph
      install` fails with "Ceph needs systemd as init system", the drop-in
      isn't installed, and `vmbr0` has its port's MAC address.
### Phase 22: fixes from the first test round

93. **pve-common `68a4417` (`9.2.3+devuan3`): LSBService: correct enabled
    state.** `service_enabled()` checked the sysv-rc start links with
    `glob()` in scalar context, an iterator that keeps its state between
    calls, so consecutive `service_status` calls (the services list of the
    web UI and API) reported enabled/disabled for the wrong script. Now in
    list context; a test checks several services one after another (all
    133 InitSystem tests pass).
94. **proxmox-kernel-helper `e44368f` (`9.2.0+devuan2`):
    proxmox-boot-cleanup's init script gets a `status` action**, reporting
    success like the one-shot unit (`RemainAfterExit=yes`); it printed the
    usage and failed before.

95. **pve-manager `8c407b80`, `f2c32987` (`9.2.21+devuan5`):
    `pve-network-interface-pinning generate` dies unless
    `/run/systemd/system` exists, before writing anything, like `pveceph
    install` (92). Checked on the laptop (no systemd): it refuses with
    "interface name pinning needs systemd-udevd, but this system wasn't
    booted with systemd".

### Phase 23: proxmox-firewall

96. **proxmox-firewall: init script** (`1896beb`, `08b56d0`; `1.2.3+devuan1`):
    - `pkg.proxmox-firewall.lsbservice` (`debian/rules`, `debian/control`):
      installs `debian/proxmox-firewall.proxmox-firewall.init` as
      `/etc/init.d/proxmox-firewall` (`dh_installinit
      --name=proxmox-firewall`: enabled, started and restarted on upgrades,
      as the unit is), skips `dh_installsystemd`, adds a lintian override
      and `${misc:Pre-Depends}`.
    - The init script: the daemon runs in the foreground (`Type=simple`),
      so `start-stop-daemon --background --make-pidfile`; stop sends
      SIGTERM, on which it removes its rules and exits within its 5 second
      loop; starting it while it runs succeeds; after pve-cluster and
      pvefw-logger, like the unit.
    - Version check in `debian/rules` ignores the `+devuan` suffix, as in
      pve-lxc-syscalld.
    - `build.sh` builds it like libpve-rs-perl: outside the repository,
      against the local proxmox-rs and proxmox-ve-rs crates
      (`[patch.crates-io]`, now generated by `local_crates_patch` for
      both); the binary lands in `target/release/`, so the build directory's
      `.install` file is adjusted. `prepare-build.sh` clones it as a changed
      repository; the pins keep `proxmox-firewall` from Proxmox's repository
      (proxmox-firewall-data, packaged separately from the repository's
      `proxmox-firewall-data/` directory and without init-system parts,
      stays Proxmox's).
    - Built with and without the profile: the default package is unchanged,
      the lsbservice one has the init script and no unit; both pass
      lintian. The init script's start, status, stop and repeated
      start/stop checked with the built daemon (as a user, without
      `/etc/pve`).

### Phase 24: fixes from the second test round

97. **pve-container `bde572b`, `44e3515` (`6.1.14+devuan2`):
    `pve-container-supervise` runs in its own cgroup.** It stayed in its
    caller's (a login session, `openrc.pvedaemon` or `openrc.pve-guests`),
    so stopping that service with OpenRC's `rc_cgroup_cleanup="YES"`, or
    logging out with elogind's `KillUserProcesses=yes`, would have killed
    the running containers with it. It now enters the resource scope
    `pve-container.slice/<vmid>.scope` through `PVE::InitSystem` (the
    dash nests it in `pve.slice`); lxc-start inherits it and moves on to
    `lxc.monitor/<vmid>`, the container stays in `lxc/<vmid>`. On exit it
    moves to the root cgroup and removes the empty scope. Tested with a
    container: the scope holds only the supervisor, also across a reboot
    from within, and is gone after stop. The post-stop hook's "Script
    exited with status 1" in `/run/pve/ct-<vmid>.stderr` after a reboot
    from within is upstream's: the hook makes lxc stop instead of reboot,
    so that the container is started again with the current config.

98. **pve-common `8ef6379` (`9.2.3+devuan4`), `96d9f00` (`9.2.3+devuan5`),
    qemu-server `55f3433`, `5f3ba69` (`9.2.10+devuan2`): remove a stopped
    VM's empty scope.**
    Without systemd, `qemu.slice/<vmid>.scope` stayed after the VM stopped
    until its next start, and for good after `qm destroy`.
    - pve-common: `PVE::InitSystem::LSBService::remove_empty_scope` removes
      a scope whose cgroup is no longer populated. An exited process counts
      as in its cgroup until it's reaped, but isn't listed in
      `cgroup.procs` any more: `qm stop` runs the cleanup as soon as QEMU's
      `/proc/<pid>/cmdline` is gone, possibly before init reaped it. So
      with no processes listed it waits up to 5 seconds for the scope to
      empty out (`96d9f00`; with `8ef6379` alone the scope stayed after
      `qm stop`). The facade exports it as
      an optional interface, only if the selected backend has it; the
      systemd backend doesn't (a test checks that), so a systemd build of
      libpve-common-perl has no `PVE::InitSystem::remove_empty_scope`.
    - qemu-server: `vm_stop_cleanup`, run after every QEMU exit (`qm
      stop`, and via qmeventd's `qm cleanup` also a kill or a shutdown from
      within), calls it if `PVE::QemuServer::BuildConfig::
      INIT_SYSTEM_LSBSERVICE`. That module is generated by
      `src/PVE/QemuServer/Makefile` from `BuildConfig.pm.in` according to
      `PVE_INIT_SYSTEM` (also for the tests); as a constant, Perl compiles
      the code out of the systemd build. Only the lsbservice build depends
      on `libpve-common-perl (>= 9.2.3+devuan4)` (`${lsbservice:Depends}`,
      set in `debian/rules`).
    - Built both ways: the lsbservice package has the dependency and the
      constant 1; the systemd one, compared with upstream, the same
      dependencies as before, the constant 0 and the new
      `BuildConfig.pm`. qemu-server's tests give the same results with
      either value as before the change.
    - Tested with the installed packages: the scope is removed after `qm
      stop` (four times), after `kill -9` (via qmeventd's `qm cleanup`) and
      with `qm destroy`. Starting the VM again within about a second of
      `qm stop` can make the next command wait for the config lock: the
      previous run's `qm cleanup` from qmeventd then finds the new QEMU and
      waits up to 30 seconds holding the lock (upstream qemu-server, not
      this change).

99. **Init scripts: pve-guests and qemu-server's qmeventd** (pve-manager
    `3fd01a4c`, `59c751cf`, `bcfbe2d4`, `9.2.21+devuan6`; qemu-server
    `13c5aa0`, `44dd63c`, `9.2.10+devuan3`).
    - pve-guests creates its stamp only when startall succeeded, like the
      unit (`Type=oneshot`, `RemainAfterExit=yes`): after a failure,
      `status` reports it stopped and `start` tries again. `stop` at
      shutdown doesn't depend on the stamp.
    - pve-guests no longer provides `pve-manager`: the unit's
      `Alias=pve-manager.service` has no LSB counterpart (a facility gives
      no `service pve-manager`), and no script depends on it.
    - qmeventd is started with stdin from `/dev/null`: its `daemon(0, 1)`
      keeps the console otherwise. Checked the other init scripts for stdin
      where it matters: pve-guests' `pvesh` calls have it since step 84;
      the PVE::Daemon daemons, pmxcfs, pvefw-logger and corosync redirect
      it themselves; `start-stop-daemon --background` (watchdog-mux,
      proxmox-firewall, pve-lxc-syscalld) and ksmtuned's `loop &` get
      `/dev/null`; `vzdump -stop` returns before forking a worker.

100. **pve-manager `1f73f452`, `32e0c047` (`9.2.21+devuan7`): the udev rule
     for pinning virtual function names only assigns a name the helper
     printed** (`RESULT=="?*"`). The helper prints nothing for every other
     interface; the rule then set `NAME=""`, which eudev applies: at boot it
     tried to rename each interface (eth0, bond0, vmbr0, tap…) to an empty
     name and logged "Error changing net interface name eth0 to : Invalid
     argument" for each. Checked with `udevadm test /sys/class/net/eth0`: no
     `NAME ''` and no rename attempt with the new rule.

Not committed: `proxmox-rs/systemd-usage-analysis.md` and
`proxmox-rs/init-system-rework.md` (untracked in proxmox-rs).

### Phase 25: rebase onto Proxmox's releases of November 2026

101. **Rebase onto the latest releases** (2026-11-10). `upstream-tags.sh`
     tagged Proxmox's latest version of each package (pve-no-subscription,
     trixie) as `proxmox/<source>/<version>`; the branches of 15
     repositories were behind. Each branch was replayed onto its tag, the
     old branch kept locally as `pre-rebase/20261110`:
     - Commits only changing `debian/changelog` (the `+devuanN` bumps) were
       dropped, the other commits replayed without their changelog
       changes. Each package then got one new `+devuan1` entry with the
       items of the old `+devuanN` entries.
     - Conflicts: version dependencies in `debian/control` (the higher one
       kept), `test/Makefile` (pve-common: both new tests), the patch
       series of ifupdown2 (ours renumbered to `pve/0019-…`) and pve-qemu
       (ours renumbered to `pve/0055-…`), pve-manager's `services/Makefile`
       (upstream's single `ceph-.service.d` drop-in, plus rbdmap and
       cephfs-mirror, in `install-systemd`), pve-storage's ESXi plugin
       imports.
     - pve-qemu moves from `stable-11.0` (11.0.3-4) to 11.1.3-1 (`master`,
       QEMU submodule `005c61c0`); all 67 patches apply to QEMU 11.1.3.
     - proxmox-rs: libpve-rs-perl 0.16.0 needs proxmox-notify 2.0.0, which
       the GitHub mirror didn't have yet; its `upstream` is now
       `git.proxmox.com/git/proxmox.git`, and the branch is based on
       `936172b0` (notify 2.0.0, the day of libpve-rs-perl 0.16.0).
       proxmox-ve-rs is pinned at `e256d0b` (ve-config 0.11.0, frr 0.6.0,
       sdn-types 0.2.5), perlmod unchanged. `cargo check` of libpve-rs-perl
       and proxmox-firewall against the local crates passes, as do the
       proxmox-apt, proxmox-apt-api-types and proxmox-log tests.
     - `upstream-systemd-scan.sh` found 9 systemd-related commits among the
       413 new upstream commits; steps 102–104 adapt the two that need it.
       corosync 3.2.0 moved its init files (`init/systemd/`, `init/other/`)
       and added OpenRC scripts in `init/openrc/`; the lsbservice profile's
       own init script is unaffected.
102. **pve-common `f123a1e` (`9.2.8+devuan1`): `PVE::InitSystem::kill_scope`.**
     Sends a signal to all processes of a scope at once: `systemctl kill
     --kill-whom=all --signal=<sig>` with systemd; `cgroup.kill` for SIGKILL
     (Linux 5.14+) or else the signal to the PIDs in `cgroup.procs` with
     LSBService. Doesn't wait; `wait_for_unit_removed` does, and removes
     the emptied scope. Tests in `initsystem-test.pl` and
     `initsystem-taint-test.pl` (under `-T`).
103. **qemu-server `f2bf9bc` (`9.2.15+devuan1`): a failed VM start's scope is
     killed via `PVE::InitSystem`.** Since 9.2.15 (`14faa1d`, fix #7590)
     the start-failure cleanup ran `systemctl kill --kill-whom=all
     --signal=KILL <vmid>.scope` and `PVE::Systemd::wait_for_unit_removed`;
     it also used `%silence_std_outs`, which step 39 removed, so after the
     replay `QemuServer.pm` didn't compile. Now `kill_scope` (errors
     ignored, as with `noerr`) and `PVE::InitSystem::wait_for_unit_removed`.
104. **pve-cluster `3a2f234` (`9.1.9+devuan1`): `pvecm updatecerts
     --rotate-ca` reloads pveproxy via the init system.** Upstream's
     `fdafbd5` ran `systemctl reload-or-restart pveproxy` on each node.
     Locally now `PVE::InitSystem::restart_service('pveproxy', 1)`
     (reload-or-restart in both backends), on other nodes
     `remote_service_cmd` with a new `reload-or-restart` action (`service
     pveproxy reload || service pveproxy restart` without systemd). The
     error message for failed nodes no longer names systemctl.
105. **Dependencies on libpve-common-perl `9.2.8+devuan1`** (pve-cluster,
     pve-network, qemu-server, pve-manager, pve-container, pve-storage,
     pve-firewall): Proxmox has released 9.2.3 and later without
     `PVE::InitSystem`, so `>= 9.2.3` no longer guarantees it.

### Changes per repository

| Repository | Base | Steps |
|---|---|---|
| pve-common | `1cd7093` (9.2.8) | 1–9, 14, 25, 31, 33–35, 38, 45, 51, 59, 74, 76, 79, 85, 93, 98, 101, 102 |
| pve-manager | `41a0e2e0` (9.2.26) | 10–13, 15–17, 20, 29, 30, 32, 37, 42, 56, 64, 65, 69, 79–81, 84, 85, 92, 95, 99–101, 105 |
| pve-cluster | `f79e17b` (9.1.9) | 18, 21, 22, 26, 52, 79, 101, 104, 105 |
| pve-ha-manager | `28c31e41` | 19, 23, 24, 27, 28, 54, 79–81 |
| qemu-server | `710476c` (9.2.15) | 36, 39–41, 55, 63, 79, 98, 99, 101, 103, 105 |
| pve-container | `00dd7c8` (6.1.18) | 43, 44, 79, 97, 101, 105 |
| pve-storage | `cdeec1e` (9.1.15) | 46–48, 79, 101, 105 |
| pve-firewall | `2ff9e4f` (6.0.7) | 49, 50, 53, 79–81, 101, 105 |
| pve-network | `4be47af` (1.6.8) | 57, 58, 60, 66, 79, 87, 101, 105 |
| pve-lxc-syscalld | `410afbcb` | 61, 79 |
| lxc | `680dfc75` | 62, 68, 79, 83 |
| ifupdown2 | `705d9a2` (3.3.0-1+pmx13) | 67, 78, 83, 101 |
| proxmox-rs | `936172b0` | 70–73, 77, 101 |
| pve-qemu | `ae7733c` (11.1.3-1) | 75, 83, 101 |
| proxmox-perl-rs | `95d60b0` (pve-rs 0.16.0) | 79, 82, 101 |
| frr | `20d9f22` | 86 |
| corosync-pve | `7c144fe` (3.2.0-pve1) | 88, 101 |
| ksm-control-daemon | `2349336` | 89 |
| proxmox-kernel-helper | `366cbf1` (9.2.1) | 90, 94, 101 |
| proxmox-ve | `75f62ea` | 91 |
| proxmox-firewall | `81ce544` (1.2.4) | 96, 101 |

All repositories are at `~/proxmox-devuan/<name>`.

Order constraints when redoing it:

- Steps 1–9 come before any consumer.
- 14 comes before 15.
- 31 and 35 can be folded into step 2.
- 33, 34 and 38 come before 36, 39 and 40.
- 45 comes before 47.
- 51 and 59 come before 58.
- 60 and 66 can be one step.

## Part C: building

Building the packages, locally or with GitHub Actions: `BUILD.md`.

## Part D: testing

In priority order. ✘ means open; the step numbers refer to Part B.

1. Full reboot:
   - ✔ boot order (pvenetcommit → networking → pve-cluster → corosync →
     daemons → pve-guests), and guests marked to start at boot started
   - ✔ shutdown order: pvescheduler → pve-guests stopall (guests shut
     down) → pve-ha-lrm → pve-ha-crm → spiceproxy → pvestatd → pveproxy →
     pvedaemon → pve-firewall → pvefw-logger → pve-cluster
2. VM lifecycle (start/stop/start via the API also done, see step 76):
   - ✔ start (QEMU in `qemu.slice/<vmid>.scope`), stop, start after
     `kill -9`; `qm reboot` uses the same stop/start
   - ✔ CPU limit hotplug (step 36): `--cpulimit 0.5` and `--cpuunits 200`
     on a running VM set the scope's `cpu.max` (50000 100000) and
     `cpu.weight` (200) at once; deleting them resets both
   - ✔ leftover scope cleanup (39): a start removes the previous, empty
     scope, and since 98 the stop (also a kill or a shutdown from within)
     removes it, as systemd does with an emptied transient scope
   - ✘ migration with conntrack state (40): needs a second node
3. ✔ Container lifecycle: start, stop, shutdown, `pct reboot`, reboot and
   poweroff from within (43), debug start (see pve-container in Part A).
4. ✘ Directory storage creation and removal (fstab entry, mount at boot;
   steps 45, 47).
5. ✘ SDN with DHCP:
   - dnsmasq instances (58, 51, 59)
   - pve-service-instances at boot
6. ✘ HA: watchdog-mux, LRM/CRM, shutdown policy detection (24).
7. ✔ Upgrade path, from upgrades of pve-container, qemu-server and
   libpve-common-perl (three runs):
   - pve-api-updates trigger (pve-manager): pvedaemon, pveproxy, pvestatd,
     spiceproxy and pvescheduler reloaded through `invoke-rc.d` (SIGHUP,
     re-exec, main PID kept since boot), like `reload-or-try-restart`
   - pve-ha-manager's trigger: pve-ha-lrm restarted ("restart LRM, freeze
     all services"), then pve-ha-crm
   - qemu-server's own scripts: qmeventd restarted,
     pve-query-machine-capabilities run; both started in OpenRC afterwards
   - pve-container (no daemons): nothing restarted besides the triggers
8. Default (systemd) builds still produce upstream's packages:
   - ✔ packages compared with `compare-default-builds.sh`: it builds each
     repository's branch and its upstream base the same way, without the
     lsbservice profile, and compares control fields, file lists,
     maintainer scripts and conffiles (report in `build/compare/report.txt`).
     18 repositories, all except proxmox-rs (no packages of its own),
     proxmox-perl-rs (only the changelog changed) and pve-qemu (no profile).
     - same packages: ksm-control-daemon, proxmox-kernel-helper,
       proxmox-ve, ifupdown2, lxc, corosync-pve, proxmox-firewall,
       pve-lxc-syscalld, frr
     - differences, all expected:
       - `libpve-common-perl (>= 9.2.3)` in the dependents (pve-cluster,
         qemu-server, pve-container, pve-storage, pve-firewall,
         pve-network, pve-manager), for the new `PVE::InitSystem` modules
       - libpve-common-perl: the `PVE/InitSystem*` modules
       - pve-container: `/usr/share/lxc/pve-container-supervise`, used only
         where the `pve-container@` units don't exist
       - maintainer scripts of pve-manager, pve-firewall and pve-ha-manager:
         an added branch for the init scripts; the systemd code runs
         unchanged when the systemd units exist or systemd is running
     - changed file contents: the code changes (they go into both builds,
       e.g. ifupdown2's `start-networking`, which keeps `--systemd` under
       systemd), plus build dates in man pages and docs and build paths
       in the Rust binaries
   - ✘ install and run the default builds on a Debian trixie systemd
     system.
