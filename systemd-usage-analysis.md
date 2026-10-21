# systemd usage in Proxmox VE

Everything known about how Proxmox VE depends on systemd, collected from the
per-repository analyses, a scan of all repositories under `~/proxmox-devuan`, and
building and running PVE on Devuan 6 "excalibur" (sysvinit as PID 1, OpenRC
as rc system). Plan and changes: `openrc-devuan.md`. Repository list and
scope: `repositories.md`. State: 2026-10-02.

**Scope:** PVE without Ceph and without ZFS. Their systemd footprint is
listed for completeness but not addressed.

More detailed sources:

- `pve-manager/systemd-usage-analysis.md`: pve-manager, as of `58350116`
- `proxmox-rs/systemd-usage-analysis.md`: the Rust crates, as of `89c1d597`
- `pve-manager/devuan-dependencies.md`: dependency closure and per-repository
  results
- `known-issues.md`: what's still broken or untested on the installed system

## How the scan was done

`git grep` over the tracked files of each repository (submodules, i.e.
vendored upstream sources, excluded; tests, docs, changelogs and
translations excluded) for:

| Category | Patterns |
|---|---|
| systemctl | `systemctl` |
| journal | `journalctl`, `mini-journalreader`, `sd_journal*`, `tracing-journald`, `systemd/journal` |
| scopes | `systemd-run`, `enter_systemd_scope`, `.scope`, `StartTransientUnit` |
| notify | `sd_notify`, `sd_listen_fds`, `NOTIFY_SOCKET`, `sd_pid_notify` |
| library/D-Bus | `libsystemd`, `org.freedesktop.systemd1`, `Net::DBus`, `proxmox-systemd`, `PVE::Systemd` |
| tmpfiles | `systemd-tmpfiles`, `tmpfiles.d`, `sysusers` |
| other tools | `loginctl`, `hostnamectl`, `timedatectl`, `systemd-escape`, `systemd-detect-virt`, `udevadm`, `networkctl`, `/run/systemd` |

plus unit files (`*.service`, `.socket`, `.timer`, `.target`, `.mount`,
`.path`, `.slice`) and `debian/control` dependencies on `systemd`,
`systemd-sysv`, `libsystemd-dev`, `libpam-systemd`, `dbus` and
`libnet-dbus-perl`. Hits were then checked by hand. False positives:
`.scope` in JavaScript (extjs, sencha-touch, biome, xterm.js, the PVE web UI),
"journal" for Ceph OSD journals and the RRD write-ahead journal, systemd
*calendar event syntax* (`PVE::CalendarEvent`, `proxmox-time`), and systemd
references in guest OS setup code (pve-container's `PVE::LXC::Setup::*`
configures systemd *inside containers*, not on the host).

## The platform: Devuan excalibur

| Fact | Consequence |
|---|---|
| No installable `systemd` / `systemd-sysv` package | Any hard `Depends: systemd` makes a package uninstallable. |
| `libsystemd0`, `libsystemd-dev` (257) available | Everything linking libsystemd builds and installs. Calls fail or no-op at runtime because nothing listens. |
| `init-system-helpers`: `update-rc.d`, `invoke-rc.d`, `service` | They drive sysv-rc *and* OpenRC. `deb-systemd-helper`/`deb-systemd-invoke` do nothing without systemd running. |
| `dh_installinit` | Generates `update-rc.d`/`invoke-rc.d` maintainer script snippets; needs `${misc:Pre-Depends}` for `invoke-rc.d --skip-systemd-native`. |
| `/etc/init.d` LSB scripts with `### BEGIN INIT INFO` headers | OpenRC runs them; `insserv` orders them for sysv-rc. |
| eudev instead of systemd-udevd | No `.link` file support (`net_setup_link`). `udevadm` exists. |
| cgroup v2 mounted, no systemd | Nothing creates slices/scopes or delegates controllers. |
| rsyslog, `/dev/log` | Normal syslog works, no journal. |
| `tzdata` without `/etc/timezone` (trixie) | Timezone comes from the `/etc/localtime` symlink. |
| `systemd-standalone-tmpfiles` available | Not used; directories are created by the init scripts. |
| `/run/systemd/system` absent | The standard test for "booted with systemd" (`sd_booted(3)`). |
| No `/etc/machine-id` (systemd creates it on Debian); dbus keeps its own `/var/lib/dbus/machine-id` | libsystemd's machine-ID functions fail. |
| `lintian` treats an init script without unit as an error | Proxmox builds run lintian and fail on errors, so overrides are needed. |

## systemd mechanisms PVE uses

Each mechanism, where it's used (in scope), and what replaces it under
OpenRC (✔ done, ✘ open, — out of scope).

### Packaging

| Mechanism | Used by | Replacement |
|---|---|---|
| `Depends: systemd` | pve-manager, pve-cluster, pve-ha-manager; also proxmox-kernel-helper, ksm-control-daemon, frr, pve-nvidia-vgpu-helper, proxmox-mini-journalreader; `Depends: systemd-sysv` in proxmox-ve (meta) | ✔ dropped by `pkg.<src>.lsbservice` build profiles in the first three; ✘ the others |
| Service units in `/usr/lib/systemd/system` | pve-manager (10 services, 1 target, 1 timer), pve-cluster, pve-ha-manager (3), qemu-server (3), pve-container (2 templates + slice), pve-firewall (2), pve-lxc-syscalld, lxc (3), ifupdown2 (3), zfs (many), ceph (many), frr, ksmtuned, proxmox-firewall, proxmox-boot-cleanup, pve-nvidia-sriov@ | ✔ LSB init scripts for all in-scope daemons (see per-project table); ✘ frr, ksmtuned, proxmox-firewall, kernel helper, vgpu helper; — zfs, ceph |
| `dh_installsystemd` / hand-written `deb-systemd-helper`/`deb-systemd-invoke` in postinst | all of the above; pve-manager by hand | ✔ `dh_installinit` with the profile; pve-manager's postinst branches on whether units are installed |
| `debian/tmpfiles` (`systemd-tmpfiles --create`) | pve-manager (`/run/pve`), qemu-server (`/run/qemu-server`) | ✔ created by init scripts |
| Timers | pve-daily-update.timer | ✔ `/etc/cron.d/pve-daily-update` with random delay (no catch-up of missed runs) |
| Targets | pve-storage.target | ✔ folded into `Should-Start:` headers |
| Drop-ins for foreign units | pve-manager (ceph-*@ ordering), pve-network (dnsmasq@ after networking) | — ceph; ✔ dnsmasq drop-in removed in the lsbservice build |
| Template units `name@instance` | pve-container@, pve-dbus-vmstate@, dnsmasq@ (SDN DHCP), zfs-import@, ceph-*@, pve-nvidia-sriov@ | ✔ pve-container-supervise; ✔ dbus-vmstate helper started directly; ✔ dnsmasq instances via the template init script with the instance as argument + `pve-service-instances` boot script; — zfs, ceph; ✘ vgpu |
| `lintian` overrides for units | pve-manager (`pvebanner.service`) | ✔ `*.lintian-overrides.lsbservice` installed only with the profile |
| logrotate `postrotate` with `systemctl` | pve-manager (pveproxy, spiceproxy) | ✔ variant file using `service … reload` |

### Runtime: service management from code

| Mechanism | Used by | Replacement |
|---|---|---|
| `systemctl start/stop/restart/reload/try-reload-or-restart` | pve-common `PVE::Daemon`, pve-manager (Services API, cert/ACME reload, pveupdate, pveceph), pve-cluster (cluster create/join, sshd/pvedaemon/pveproxy reload), pve-firewall (pvefw-logger), pve-network (frr, faucet, dnsmasq@) | ✔ `PVE::InitSystem::{start,stop,restart,reload,try_reload_or_restart}_service` |
| `systemctl show` (state, description, MainPID) | pve-manager Services API, Ceph OSD details | ✔ `service_status`, `service_main_pid`; — Ceph |
| `systemctl enable/disable [--runtime]` | pve-network (frr, dnsmasq@), pve-storage (zfs-import@), Ceph | ✔ `enable_service`/`disable_service`; — Ceph |
| `systemctl is-enabled`, `*.target.wants` symlink checks | pve-network (frr), pve-manager Ceph | ✔ `service_status`; — Ceph |
| `systemctl` on **remote** nodes over ssh | pve-cluster pvecm (corosync-qdevice), pve-manager `pve-cephx-rotate-service-keys` | ✔ pvecm builds a command that checks `/run/systemd/system` on the remote side; — Ceph |
| "started by the init system" = parent is PID 1 | pve-common `PVE::Daemon` | ✔ `started_by_init()`, plus `PVE_INIT_SCRIPT=1` exported by init scripts (otherwise `pvedaemon start` from an init script calls `service pvedaemon start` again → endless recursion) |
| `systemctl --full list-jobs` / `list-jobs` (shutdown vs. reboot) | pve-ha-manager LRM; ifupdown2 `start-networking stop` (`SKIP_DOWN_AT_SYSRESET`) | ✔ runlevel 0/6 if not booted with systemd (ifupdown2 also OpenRC's `RC_RUNLEVEL`) |
| `systemctl reboot/poweroff` | proxmox-rs `proxmox-node-status` (PBS/PDM) | not used by PVE (`/sbin/reboot`, `/sbin/poweroff`) |
| `systemctl is-active/is-enabled` | pve-manager `pve8to9`, proxmox-rs `proxmox-upgrade-checks` | irrelevant for Devuan |

### Runtime: cgroups and transient units

| Mechanism | Used by | Replacement |
|---|---|---|
| Transient scope via D-Bus `StartTransientUnit` (`enter_systemd_scope`), with `Slice=`, `CPUQuota`, `CPUWeight`, `KillMode`, `SendSIGKILL`, `TimeoutStopUSec` | qemu-server (each VM in `qemu.slice/<vmid>.scope`), pve-storage (ESXi FUSE mount), pve-common | ✔ LSBService backend creates cgroup v2 directories in the requested slice (dash nesting like systemd), delegates cpu/io/memory/pids controllers down the tree, maps CPUQuota/CPUWeight to `cpu.max`/`cpu.weight`, rejects CPUShares |
| D-Bus `SetUnitProperties` on a running scope | qemu-server `PVE::QemuServer::CGroup` (CPU limit/weight hotplug) | ✔ `set_scope_properties` (writes `cpu.max`/`cpu.weight`) |
| Waiting for a unit to disappear (D-Bus job signals), `is_unit_active` | qemu-server, pve-storage ESXi | ✔ poll `cgroup.events` for `populated 0`, then remove the directory |
| `systemctl stop <scope>`, `systemctl reset-failed` | qemu-server (leftover VM scope), pve-storage ESXi | ✔ `stop_scope` (SIGTERM, timeout, `cgroup.kill`), `reset_failed` (no-op) |
| `Type=notify` service + `sd_notify(READY=1)` | qemu-server dbus-vmstate helper, pve-lxc-syscalld, proxmox-rs `proxmox-daemon` | ✔ dbus-vmstate: own `NOTIFY_SOCKET`, start waits for READY=1; ✔ pve-lxc-syscalld: sd_notify is a no-op without `NOTIFY_SOCKET`, init script waits for the socket |

### Runtime: logging

| Mechanism | Used by | Replacement |
|---|---|---|
| `journalctl` (syslog API) | pve-common `PVE::Tools::dump_journal` → pve-manager `GET /nodes/{node}/syslog` | ✔ `PVE::InitSystem::dump_syslog` reads rsyslog files (RFC 3339 and traditional timestamps), filters by tag/since/until; aliases `sshd`, `syslog`, `postfix@-` mapped |
| `mini-journalreader` (journal API with cursors) | pve-manager `GET /nodes/{node}/journal`; GUI journal views (proxmox-widget-toolkit `JournalView.js`, pve-yew-mobile-gui) | ✔ API returns 501 Not Implemented without mini-journalreader; ✘ GUIs should fall back to the syslog API |
| `journalctl --sync` before watchdog expiry | pve-ha-manager watchdog-mux | ✔ falls back to `sync(2)` |
| Daemon stderr to the journal | watchdog-mux (logs to stderr), proxmox-rs daemons | ✔ watchdog-mux: init script redirects to `/var/log/watchdog-mux.log` + logrotate `copytruncate` |
| `tracing-journald` (`proxmox-log`) | Rust code in libpve-rs-perl (all PVE daemons and CLI tools), proxmox-rs daemons | ✔ falls back to syslog (`/dev/log`, own RFC 3164 writer) and then stderr; proxmox-rs `4b8d3d2d` |
| `sd_journal_stream_fd` | proxmox-rs `proxmox-daemon` (re-exec) | not used by PVE |

### Runtime: system configuration

| Mechanism | Used by | Replacement |
|---|---|---|
| `timedatectl` / D-Bus timedate1 | pve-common timezone functions → pve-manager time API | ✔ `/etc/localtime` symlink, `/etc/timezone` kept in sync where it exists, zone list from TZif files |
| Mount units in `/etc/systemd/system` (enabled for boot), runtime mount units | pve-storage disk API (directory storages), CephFS plugin | ✔ `PVE::InitSystem` mount functions: marked `/etc/fstab` entries (mounted by `mountall.sh`), plain mounts at runtime |
| `zfs-import@<pool>.service` | pve-storage disk API (ZFS) | ✔ only touched if the init system has the service; — pool import at boot (ZFS out of scope, see `known-issues.md`) |
| `.link` files (`/usr/lib/systemd/network/…`, `/usr/local/lib/systemd/network/50-pve-*.link`) | pve-manager `proxmox-ve-default.link` (MACAddressPolicy=none), `pve-network-interface-pinning`, `virtual-function-pinning-helper` | ✘ ignored by eudev; pinning needs udev rules instead; the MAC policy is likely unnecessary with eudev (unverified) |
| `sd_id128_get_machine_app_specific` (subscription server ID) | proxmox-rs `proxmox-subscription` via libpve-rs-perl → pve-manager subscription API | needs `/etc/machine-id`, which nothing creates on Devuan (only dbus's `/var/lib/dbus/machine-id` exists). Without it, falls back to the SSH host key's MD5 (`SSH MD5` candidate), so the server ID changes if the host keys are regenerated. ✔ `pve-machine-id` init script in pve-common's lsbservice build (`1865f24`) creates it |
| `udevadm trigger/settle` | pve-storage `PVE::Diskmanage`, ifupdown2 | works with eudev |

## Per-project inventory (in scope)

"Footprint" is the original systemd use on `master`; "Now" is the state on
the `feature/init-systems-refactoring` branches built with the lsbservice
profile.

| Project | Footprint on master | Now |
|---|---|---|
| **pve-common** | `PVE::Systemd`: D-Bus transient scopes, unit wait/active, timezone via timedatectl, `systemctl` in `PVE::Daemon`, `journalctl` in `PVE::Tools::dump_journal`; `Depends: libnet-dbus-perl` | `PVE::InitSystem` facade with Systemd and LSBService backends selected at build time; all of the above, plus service state/enable/syslog, scope properties/stop, mounts, template instances, `started_by_init`; `pve-service-instances` init script |
| **pve-manager** | 13 units, `Depends: systemd`, `proxmox-mini-journalreader`, postinst via deb-systemd-*, tmpfiles, `systemctl` in Services/Certificates/ACME/pveupdate/pveceph/logrotate, journal APIs, `.link` files, Ceph management | 10 init scripts + cron job + logrotate variant; Perl code via `PVE::InitSystem` (enforced by `make check`); postinst/postrm for both variants. Open: Ceph (out of scope), `.link`-based NIC pinning, pve8to9 (irrelevant) |
| **pve-cluster** | `pve-cluster.service`, `Depends: systemd`, `systemctl` in cluster create/join and pvecm QDevice handling | init script for pmxcfs; `PVE::InitSystem`; remote QDevice commands decide per node |
| **pve-ha-manager** | 3 units, `Depends: systemd`, `systemctl list-jobs`, `journalctl --sync` | 3 init scripts (watchdog-mux backgrounded with log file + logrotate, OOM score -1000), runlevel-based shutdown detection, `sync(2)` fallback |
| **qemu-server** | qmeventd, pve-query-machine-capabilities, pve-dbus-vmstate@ units; `Depends: dbus, libnet-dbus-perl`; VM scopes, `SetUnitProperties`, `systemctl stop/reset-failed`, tmpfiles | 2 init scripts; scopes, properties and cleanup via `PVE::InitSystem`; dbus-vmstate helper started directly in its scope with its own notify socket. dbus/libnet-dbus-perl still needed for the dbus-vmstate helper itself |
| **pve-container** | `pve-container@`/`pve-container-debug@` template units + slice, stop wrapper restarting rebooted containers | `pve-container-supervise` (detached `lxc-start -F`, stderr log, restart on reboot from within) where the service doesn't exist |
| **pve-storage** | mount units, runtime mount units (CephFS), `zfs-import@`, `systemctl stop/reset-failed` for the ESXi scope | `PVE::InitSystem` mounts (fstab), zfs-import@ only if present, `stop_scope`/`reset_failed` |
| **pve-firewall** | pve-firewall and pvefw-logger units, `systemctl try-reload-or-restart pvefw-logger` | 2 init scripts (legacy iptables alternatives, `START_FIREWALL`), facade reload |
| **pve-network** | `systemctl` for frr (enable --now, restart), faucet reload, dnsmasq@ instances, dnsmasq unit file check, dnsmasq@ drop-in | facade for all; dnsmasq instances via the template init script; frr via `frrinit.sh` directly if there's no frr service (no start at boot, ✘) |
| **pve-lxc-syscalld** | `Type=notify` unit with `RuntimeDirectory=`, `sd_notify` | init script (backgrounded, waits for the socket, runtime directory) |
| **lxc** (lxc-pve) | lxc, lxc-net, lxc-monitord units | 3 init scripts; lxc also loads the AppArmor profiles (upstream's sysvinit script doesn't); creates `/var/lock/subsys` to avoid the lock collision with liblxc |
| **ifupdown2** | networking.service, ifupdown2-pre.service, ifup@.service; Devuan's ifupdown2 has no init script, so installing it (pulled in by pve-network) removes ifupdown and with it network setup at boot | `networking` init script in rcS (udev settle, `/etc/default/networking`, `start-networking`) |
| **proxmox-perl-rs** (libpve-rs-perl, libproxmox-rs-perl) | links libsystemd via `proxmox-systemd` (from proxmox-rs), `proxmox-log` journald layer | links libsystemd0 (available); rebuilt with the fixed `proxmox-apt` and `proxmox-log` |
| **proxmox-rs** | `proxmox-systemd` FFI, `proxmox-log`, `proxmox-syslog-api`, `proxmox-node-status`, `proxmox-upgrade-checks` | unchanged; only `proxmox-log` matters for PVE (see above); plan in `proxmox-rs/init-system-rework.md` |
| **proxmox-widget-toolkit**, **ui** | journal views use the journal API | ✘ need a syslog fallback when the journal API returns 501 |

### In scope, no systemd use

pve-access-control, pve-guest-common, pve-apiclient, pve-http-server,
proxmox-acme, perlmod, librados2-perl, pve-qemu (links libsystemd for QEMU's
own optional use; available), pve-edk2-firmware, proxmox-websocket-tunnel,
pve-xtermjs (termproxy), spiceterm, vncterm, proxmox-mail-forward,
proxmox-i18n, pve-docs, extjs, fonts-font-logos, libjs-qrcodejs, novnc-pve,
proxmox-enterprise-support, proxmox-backup-qemu, proxmox-backup client
packages (the server part is systemd-bound but not needed), proxmox-ve-rs
(only false positives), proxmox-firewall-data.

### Devuan packages used instead of Proxmox builds

corosync and lxcfs (with Devuan init scripts), chrony, postfix, rsyslog,
cron, openssh-server, open-iscsi, dnsmasq (init script supports instances),
rrdcached.

### Not installed yet, with systemd dependencies

| Project | Footprint | Needed for |
|---|---|---|
| proxmox-ve (meta) | `Depends: systemd-sysv` | the `proxmox-ve` meta package |
| proxmox-kernel-helper | `Depends: systemd`, `proxmox-boot-cleanup.service` | `proxmox-boot-tool`, required by proxmox-ve |
| ksm-control-daemon | `Depends: systemd`, `ksmtuned.service` only | KSM tuning, required by proxmox-ve |
| frr (Proxmox build) | `Depends: systemd`, units only | SDN fabrics/EVPN; Devuan's frr has no init script either |
| pve-vgpu-helper | `Depends: systemd`, `pve-nvidia-sriov@.service` | NVIDIA vGPU (recommended by pve-manager) |
| proxmox-firewall | `proxmox-firewall.service`, `systemctl` in `firewall.rs` | nftables firewall (recommended by pve-manager) |

## Out of scope

| Area | Footprint |
|---|---|
| **Ceph** | Daemons ship only systemd units (`ceph-*@.service`, `ceph*.target`); pve-manager's `PVE/Ceph/Services.pm` (enable/disable/start/stop instances, `*.target.wants` scan), `PVE/API2/Ceph/OSD.pm` (`MainPID`, `disable --runtime`), `pveceph` and `pve-cephx-rotate-service-keys` (remote `systemctl`), ceph-crash restart in postinst (skipped in the lsbservice variant), ceph-*@ drop-ins. Only the client libraries are installed. |
| **ZFS** | Proxmox's zfs build ships only systemd units (`zfs-import-cache/scan`, `zfs-mount`, `zfs-share`, `zfs-zed`, `zfs-import@`, scrub/trim timers); upstream's init scripts are built but listed in `debian/not-installed`. pve-storage only touches `zfs-import@` if the init system has it. |
| Other products | PBS server, PMG, PDM: units, `systemctl`, journal APIs, `proxmox-systemd`; see `proxmox-rs/systemd-usage-analysis.md` |
