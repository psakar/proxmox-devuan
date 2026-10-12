# Known issues: PVE on Devuan (OpenRC) on nb-devuan

State after installing pve-manager 9.2.21 with the `pkg.*.lsbservice` builds
on 2026-10-02. Details on the packages and commits are in
`pve-manager/devuan-dependencies.md`.

## watchdog-mux holds the hardware watchdog

pve-ha-manager (pulled in as a pve-manager dependency) starts `watchdog-mux`,
which opens `/dev/watchdog`, here the laptop's hardware watchdog (`iTCO_wdt`).
If the process is killed without a clean stop (e.g. `kill -9`, OOM), the
watchdog isn't disarmed and the **machine resets**. Stop it only with
`rc-service watchdog-mux stop`.

## "Unable to open syslog" on every PVE command and daemon start (fixed)

`proxmox-log` (Rust, in libpve-rs-perl) tried only the journald socket and,
without it, printed `Unable to open syslog: Os { code: 2, … }` and logged
to stderr, which is lost for daemons.

**Fixed** on 2026-10-02 (proxmox-rs `4b8d3d2d`): without journald it now
logs to syslog (`/dev/log`, facility daemon, identifier = program name).
libpve-rs-perl was rebuilt and installed; the message is gone, and Rust log
messages end up in `/var/log/syslog`.

## Package removals today not caused by the PVE install

- `firmware-iwlwifi` was removed at 15:44 by `apt install proxmox-default-kernel`:
  `pve-firmware` replaces it (and contains the iwlwifi firmware).
- `exim4` was removed at 15:50 by `apt install postfix open-iscsi chrony`:
  postfix replaces it.

## /etc/hosts changed

pmxcfs (pve-cluster) needs the hostname to resolve to a non-loopback
address, so the `127.0.1.1 nb-devuan …` line was changed to `192.168.2.14`.
If the laptop gets a different address, pve-cluster won't start until this is
updated. Backup of the original: `/etc/hosts.before-pve`.

## Packages replaced by the install

- `ifupdown` → `ifupdown2` (our build 3.3.0-1+pmx12, from `ifupdown2`
  with a new `networking` init script; Devuan's ifupdown2 has none, so nothing
  would bring the network up at boot).
- Devuan's `lxc`/`liblxc` → `lxc-pve`. Devuan's `lxc` is still in state `rc`
  (config files kept). Its `/etc/init.d/lxc` and `lxc-net` were left with
  mode 644 after lxc-pve took them over and had to be made executable again;
  a fresh install isn't affected.

## /etc/machine-id was missing: subscription server ID from the SSH host key

On Debian, systemd creates `/etc/machine-id`; on Devuan nothing does (dbus
keeps its own `/var/lib/dbus/machine-id`). The subscription server ID is
computed in libpve-rs-perl (`proxmox-subscription`) via libsystemd's
`sd_id128_get_machine_app_specific()`, which needs that file. It fails
silently and falls back to the MD5 of the SSH host key:
`pvesubscription get` reports `serverid: F9F8C5B958E5D8DE380C43FB85E6BD04`
(candidate `SSH MD5`). Nothing breaks, but regenerating the SSH host keys
changes the server ID, which would invalidate a subscription key.

**Worked around** on 2026-10-02, before the fix below, with
`sudo dbus-uuidgen --ensure=/etc/machine-id`. The server ID is now
`E4BF5E38F46B4461BE66249CAF70483C` (candidate `machine-id`, listed first),
with `SSH MD5` as the second candidate. pve-manager's local check
(`PVE/API2/Subscription.pm`) accepts a stored server ID matching any
candidate; whether Proxmox's subscription server does is unverified.

That command generated a new ID instead of reusing dbus's: `/etc/machine-id`
(`02dcf159…`) and `/var/lib/dbus/machine-id` (`0b80f3dc…`) differ, while on
systemd systems the latter is a symlink to the former. Harmless for PVE, but
the planned fix reuses dbus's ID.

**Fixed** for new installations: pve-common's lsbservice build now ships a
`pve-machine-id` init script (pve-common `1865f24`). It creates the file at
boot and on installation if it's missing, reusing D-Bus's ID, and never
changes an existing one. A machine worked around as above keeps its
hand-made ID, so the mismatch with D-Bus's ID remains there.

## APT repositories view fails: Devuan's codename isn't recognized

`pvesh get /nodes/<node>/apt/repositories` (GUI: Node → Repositories) fails
with `proxmox-apt error - unknown Debian code name 'excalibur'`. Adding a
standard repository via the API fails the same way.

The cause is in proxmox-rs: `proxmox-apt`'s `get_current_release_codename()`
reads `VERSION_CODENAME` from `/etc/os-release`, and `DebianCodename` only
knows Debian's codenames. The package list (`/apt/versions`) and updates
(`apt-get update` via `pveupdate`) work. **Fixed** in proxmox-rs (branch `feature/init-systems-refactoring`,
`5bb1c086`..`6337ef1a`) and **deployed** on 2026-10-02: libpve-rs-perl
0.15.3 was rebuilt against the local proxmox-rs checkout and installed. The
repositories API now lists all files without errors, with origin "Devuan"
for the Devuan sources.

## Enterprise repository was enabled without subscription

pve-manager ships `/etc/apt/sources.list.d/pve-enterprise.sources` (enabled),
as on any PVE installation. Without a subscription key, `apt-get update`
fails for it with `401 Unauthorized`. The system's apt has none of the
private fetch configuration's pins, so enabling a working Proxmox repository
at system level (e.g. no-subscription) could replace the lsbservice builds
with Proxmox's and pull in Proxmox's systemd packages. Keep Proxmox's
repositories out of the system's apt.

**Done** on 2026-10-02: `Enabled: no` added to the file, so `apt-get update`
runs without errors and the repositories API reports it as disabled. The
original is in `/var/backups/pve-enterprise.sources.before-disable`. The file
is a conffile of pve-manager, so upgrades keep the change and only ask if
the packaged version changes.

## apt reports "Permission denied" for the local repository

`apt-get update` prints `Err: file:/home/saki/proxmox/repo ./ Packages …
Permission denied`, because apt's `_apt` sandbox user can't enter
`/home/saki` (mode 700). apt then reads it as root (`Get: … Packages`), so
the index is loaded. Cosmetic; moving the repository out of the home
directory (e.g. `/srv/proxmox-devuan-repo`) would avoid it.

## Node status "unknown" (1): Devuan's default corosync.conf

Devuan's (Debian's) corosync package ships a working
`/etc/corosync/corosync.conf` (cluster `debian`, single node `node1` at
127.0.0.1), and its init script starts corosync at boot. Proxmox's corosync
build ships that file only as an example in `/usr/share/doc`.

When pve-cluster was installed, pmxcfs found the file, started in cluster
mode and imported it as `/etc/pve/corosync.conf`. `nb-devuan` wasn't a member
of that "cluster", so `/cluster/resources` reported its status as `unknown`
and `/cluster/status` showed cluster `debian` with `node1`.

**Fixed** on 2026-10-02:
- stopped pve-cluster and corosync
- started `pmxcfs -l` (local mode)
- moved `/etc/pve/corosync.conf` and `/etc/corosync/corosync.conf` to
  `/var/backups/{pve-,}corosync.conf.devuan-default`
- restarted pve-cluster
- `update-rc.d corosync disable`

`/cluster/status` now shows the standalone node `nb-devuan`, online. dpkg
keeps the deleted conffile deleted on upgrades.

**Fixed in the build** (`openrc-devuan.md`, step 88): corosync is now
Proxmox's, built with an init script (`pkg.corosync.lsbservice`), and it
ships no `corosync.conf`; its init script stays enabled and doesn't start
corosync until the node is part of a cluster.

## Node status "unknown" (2): pvestatd hangs on the QEMU CPU flag query

pve-qemu-kvm's patch `0030-PVE-redirect-stderr-to-journal-when-daemonized`
makes a daemonized QEMU send its stderr to the journal via
`sd_journal_stream_fd()`. Without journald that returns an error, the result
isn't checked, and `dup2()` fails, so the daemonized QEMU keeps the caller's
stderr open.

- **pvestatd:** it runs such a QEMU at startup to query the supported CPU
  flags (`query_supported_cpu_flags`, VM id `-1`, once with TCG and once
  with KVM), and `run_command` waits forever for the pipe to close. So
  pvestatd sent no status at all, and the node stayed `unknown` even after
  the corosync fix. Reproduced without PVE: `kvm … -daemonize 2>&1 | cat`
  never returns.
- **VM starts:** `qm start`/`vm_start` start QEMU the same way and would
  have hung too.

**Workaround** (temporary): kill the query QEMU (`kill $(cat
/var/run/qemu-server/-1.pid)`). pvestatd then continues and reports the
node `online`, but the query failed, so it retries after 120 seconds and
hangs again.

**Fixed** on 2026-10-02: pve-qemu-kvm `11.0.3-4+devuan1` (pve-qemu
`d0d9eab`) falls back to syslog when there's no journald, so a daemonized
QEMU's messages end up in `/var/log/syslog` as `QEMU[<pid>]`. Installed;
pvestatd's CPU flag query completes and the node stays online, and VM 100
starts through the API.

## VM start via the API failed: "Insecure dependency in rmdir"

`TASK ERROR: Insecure dependency in rmdir while running with -T switch at
/usr/share/perl5/PVE/InitSystem/LSBService.pm line 616`, on starting a VM
from the GUI/API after it had run before.

- **Cause:** pvedaemon runs with taint checks (`perl -T`), and the
  LSBService backend removed the VM's leftover empty scope through a path
  found via `glob()`, which is tainted. systemd removes empty transient
  scopes itself; here it's done on the next start.
- **Same problem:** in `stop_scope` (PIDs read from `cgroup.procs`) and for
  template instance markers. Tests with `qm` (no `-T`) didn't show it.

**Fixed** on 2026-10-02 (pve-common `7fbdbc2`, with a test running under
`perl -T`): installed, and VM 100 started, stopped and started again
through the HTTPS API.

## ifupdown2 deconfigured the network at every shutdown

`/usr/share/ifupdown2/sbin/start-networking stop` (run by the `networking`
init script) detected a shutdown/reboot with `systemctl list-jobs`, to keep
the interfaces configured then (`SKIP_DOWN_AT_SYSRESET=yes`). Without
systemd that always failed.

A local edit of the installed script (`rc-status --runlevel` and
`pgrep -f …`) missed reboots and could match unrelated processes; it's saved
in `/var/backups/start-networking.local-fix`.

**Fixed** on 2026-10-03 (ifupdown2 `24b1e04`, `3.3.0-1+pmx12+devuan1`): the
runlevel decides (0/6), or OpenRC's `RC_RUNLEVEL`. The installed package
replaced the local edit. Not yet verified with a real reboot.

## Package upgrades failed: init scripts' start on a running daemon

Upgrading pve-firewall failed in its maintainer script:
`invoke-rc.d pve-firewall start` returned an error, because the daemon's own
`start` refuses to run twice ("can't acquire lock ... daemon already
started"). pve-manager, qemu-server, pve-container and pve-ha-manager then
stayed unconfigured. The same applied to pvedaemon, pveproxy, spiceproxy,
pvestatd, pvescheduler, pve-ha-crm and pve-ha-lrm; systemd never runs
`ExecStart=` for an active unit, so this didn't show there.

**Fixed** on 2026-10-03 (pve-manager `cf716c0b`, pve-firewall `6ef89ae`,
pve-ha-manager `21c88ba`, as `+devuan2`): `start` exits 0 if the pid file
names a running process. The half-configured packages were configured with
`dpkg --configure -a`; everything is `ii` again.

## Guests weren't started at boot: pve-guests' worker and the console

At boot, the pve-guests init script failed (pve2, `/var/log/boot`):

```
failed to tcsetpgrp: Inappropriate ioctl for device
got no worker upid - start worker failed
 * ERROR: pve-guests failed to start
```

`pvesh create /nodes/localhost/startall` runs a synchronous worker, and
pve-common's `fork_worker` gives the worker the terminal when stdin is one
(`setpgid` and `tcsetpgrp`, `RESTEnvironment.pm`). OpenRC runs init scripts
with the console as stdin, but it isn't their controlling terminal, so
`tcsetpgrp` fails with ENOTTY and the worker dies before reporting its task
ID. No guest marked `onboot` was started, and `stopall` at shutdown would
have failed the same way. pve-guests.service has stdin on `/dev/null`, so
this didn't show with systemd.

**Fixed** on 2026-10-07 (pve-manager `82f95a01`, as `+devuan3`): the init
script runs both `pvesh` calls with stdin from `/dev/null`. Not yet
verified with a reboot.

## Node "System Log" and service logs empty in the web UI

The node's "System Log" panel and the per-service logs (node → System →
a service's log) showed nothing. Both use the journal API
(`/nodes/{node}/journal`), served by mini-journalreader from systemd's
journal; without it the API returned 501. The syslog API, which reads
`/var/log/syslog`, worked, but the UI doesn't use it.

**Fixed** on 2026-10-07 (pve-common `cccffb1`, `+devuan2`; pve-manager
`ef8bd820`, in `+devuan3`): without mini-journalreader the journal API
reads the syslog files via `PVE::InitSystem::read_journal`, in the plain
format the UI's journal view accepts. The priority filter has no effect
(the files don't record the priority), lines aren't coloured, and the
identifier and unit filter lists stay empty. Needs rsyslog (see the install
prerequisites in `openrc-devuan.md`). Not yet verified in the UI.

## ZFS pools aren't imported or mounted at boot

Proxmox's ZFS packages (`zfsutils-linux` 2.4.4-pve1 and its libraries,
from `zfsonlinux`, installed as dependencies of the storage stack) ship
only systemd units (`zfs-import-cache`, `zfs-import-scan`, `zfs-mount`,
`zfs-share`, `zfs-zed`, `zfs-import@`, …), no init scripts. Debian's own
packaging installs upstream OpenZFS's `/etc/init.d` scripts; Proxmox's
build creates them too, but lists `etc/init.d` in `debian/not-installed`.
Shipping them in an lsbservice profile would be the fix. So on Devuan nothing
imports or mounts ZFS pools at boot, and ZED doesn't run. ZFS is **out of
scope** for now (see below).

## Out of scope for now: Ceph and ZFS

The current scope is PVE without Ceph and without ZFS:

- **Ceph:** only the client libraries (librados2, librbd1, … 19.2 from
  Proxmox's ceph-squid repo) are installed, as dependencies of pve-qemu-kvm
  and the storage stack. Ceph's daemons ship only systemd units, and
  pve-manager's Ceph management (`PVE/Ceph/*`, `pveceph`,
  `pve-cephx-rotate-service-keys`) still calls `systemctl`.
- **ZFS:** the userland is installed as a dependency, but there's no boot
  integration (above). pve-storage only touches `zfs-import@` units if the
  init system has them (pve-storage `0a98c48`).

## Not tested yet

- VM and container start/stop/reboot
- HA
- SDN with DHCP (dnsmasq instances)
- directory storage creation (fstab mounts)
- a full reboot: boot order of all init scripts, network via ifupdown2,
  pmxcfs before the other daemons
