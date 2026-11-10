# Installing Proxmox VE on Devuan 6 with OpenRC

## Prerequisites

- **Devuan 6 excalibur (amd64) with the OpenRC init system** (sysvinit as
  PID 1, OpenRC as rc), which the packages' init scripts are made for:

  ```
  cat /etc/devuan_version     # excalibur
  ls -d /run/openrc           # exists when booted with OpenRC
  ```

  Devuan's default rc is sysv-rc; `sudo apt install openrc` replaces it,
  followed by a reboot.

- **A syslog daemon.** Without journald, the PVE daemons log through syslog
  (`/dev/log`); a minimal installation has none, and every daemon then
  reports "Unable to open journald … or syslog" and logs nothing:

  ```
  sudo apt install rsyslog
  ls -l /dev/log                    # exists once rsyslog runs
  ```

- **The loopback interface up**, configured in `/etc/network/interfaces`:
  pvedaemon listens on `127.0.0.1:85` and otherwise fails with "unable to
  create socket - Cannot assign requested address":

  ```
  ip addr show lo                   # UP, with 127.0.0.1/8
  grep -A1 '^auto lo' /etc/network/interfaces
  ```

  The file must contain:

  ```
  auto lo
  iface lo inet loopback
  ```

  ifupdown2, installed with Proxmox VE, writes its own copy of the
  configuration to `/etc/network/interfaces.new`, applied at the next
  reboot; it must keep these lines too.

## 1. APT repositories setup

A Devuan 6 machine installs Proxmox VE from three sources:

- Devuan's repositories
- Proxmox Devuan Repository - Proxmox packages rebuilt for Devuan
- Proxmox's repository `pve-no-subscription` for the kernel and the
  unchanged Proxmox packages, pinned so it doesn't replace Devuan's or the
  packages built for Devuan

Create the local Proxmox Devuan Repository from a GitHub release (replace
`<tag>` with a release tag from
`https://github.com/psakar/proxmox-devuan/releases`):

```
sudo apt install gpgv
sudo wget https://raw.githubusercontent.com/psakar/proxmox-devuan/main/keys/proxmox-devuan-repo.asc \
    -O /usr/share/keyrings/proxmox-devuan-repo.asc
gpg --show-keys /usr/share/keyrings/proxmox-devuan-repo.asc
# must show 36B20B82FF0808507F8186B3F9A37E6E8F366387
wget https://github.com/psakar/proxmox-devuan/releases/download/<tag>/proxmox-devuan-repo-<tag>.tar.gz \
    https://github.com/psakar/proxmox-devuan/releases/download/<tag>/proxmox-devuan-repo-<tag>.tar.gz.asc
gpg --dearmor < /usr/share/keyrings/proxmox-devuan-repo.asc > /tmp/proxmox-devuan-repo.gpg
gpgv --keyring /tmp/proxmox-devuan-repo.gpg proxmox-devuan-repo-<tag>.tar.gz.asc proxmox-devuan-repo-<tag>.tar.gz
sudo mkdir -p /srv/proxmox-devuan-repo
sudo tar -xzf proxmox-devuan-repo-<tag>.tar.gz -C /srv/proxmox-devuan-repo
# apt reads local repositories as the _apt user
sudo chown -R _apt:root /srv/proxmox-devuan-repo
```

## 2. Apt configuration

Proxmox's signing key, checked by its fingerprint:

```
sudo wget https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
    -O /usr/share/keyrings/proxmox-release-trixie.gpg
gpg --show-keys /usr/share/keyrings/proxmox-release-trixie.gpg
# must show 24B30F06ECC1836A4E5EFECBA7BCD1420BFE778E
```

The sources: Proxmox Devuan Repository and Proxmox's (apt only reads
`.list` and `.sources` files in `sources.list.d`):

```
sudo tee /etc/apt/sources.list.d/proxmox-devuan-install.sources >/dev/null <<'EOF'
Types: deb
URIs: file:/srv/proxmox-devuan-repo
Suites: ./
Signed-By: /usr/share/keyrings/proxmox-devuan-repo.asc

Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-release-trixie.gpg
EOF
```

Proxmox Devuan Repository is flat (suite `./`, no components); apt checks
its signature with the key from step 1.

The pins:

```
sudo tee /etc/apt/preferences.d/proxmox-devuan-install >/dev/null <<'EOF'
# Proxmox Devuan Repository (the packages built for Devuan) always wins
Package: *
Pin: origin ""
Pin-Priority: 1001

# Proxmox's repository: only where Devuan doesn't have a suitable version
Package: *
Pin: origin download.proxmox.com
Pin-Priority: 100

# never take these from Proxmox: systemd, and the packages built for Devuan
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

# qemu-server needs Proxmox's swtpm 0.10.2 or newer, Devuan has 0.7.1
Package: swtpm swtpm-* libtpms*
Pin: origin download.proxmox.com
Pin-Priority: 600

# Secure Boot (proxmox-secure-boot-support): Proxmox's shim and GRUB, which
# load its signed kernel, not Devuan's (Debian's)
Package: shim-* grub-* grub2-common proxmox-grub
Pin: origin download.proxmox.com
Pin-Priority: 600
EOF
```

- Without the systemd pin, Proxmox's systemd packages would replace Devuan's.
- Without the second -1 pin, a newer Proxmox release of a package built for
  Devuan (e.g. pve-manager 9.2.22 over 9.2.21+devuan2) would replace it with
  the systemd-only original. Upgrades of those come from rebuilds; keep the list
  in sync with `build.sh`'s packages.
- `frr frr-*` in that list: pve-network recommends `frr-pythontools (>=
  10.3.1-1+pve2~)`, which Devuan's frr (10.3) doesn't satisfy, so apt would
  otherwise take Proxmox's frr, which has only systemd units, no init
  script; with the pin, frr comes from `/srv/proxmox-devuan-repo`.
- The corosync packages in that list: Devuan's corosync would otherwise be
  preferred (priority 500 over Proxmox's 100), and it ships a default
  `/etc/corosync/corosync.conf` that pmxcfs takes for a cluster
  (`known-issues.md`); the one from `/srv/proxmox-devuan-repo` doesn't. It needs
  Proxmox's kronosnet (`libknet*`, `libnozzle*`), hence their 600 pin, like
  the Ceph libraries'.
- qemu-server needs Proxmox's swtpm (`swtpm-tools (>= 0.10.2+pve1)`, with
  `swtpm`, `swtpm-libs`, `libtpms0`), newer than Devuan's 0.7.1, hence the
  600 pin for `swtpm*` and `libtpms*`.
- A newer unchanged Proxmox package may need a newer version of one built
  for Devuan; apt then holds it back until that's rebuilt.

## 3. Apt update

```
sudo apt update
apt-cache policy pve-manager systemd
```

pve-manager's candidate is the `+devuan` version from
`/srv/proxmox-devuan-repo`, systemd's Devuan's.

## 4. Install Proxmox kernel and the boot loader

Install the kernel, as in Proxmox's guide [Install Proxmox VE on Debian 13
Trixie: Install the Proxmox VE
Kernel](https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie#Install_the_Proxmox_VE_Kernel):

```
sudo apt install -y proxmox-default-kernel
```

Before rebooting into it, set up the boot loader for how the machine
boots: legacy BIOS, or UEFI with Secure Boot. What it booted with now:

```
[ -d /sys/firmware/efi ] && echo UEFI || echo "legacy BIOS"
```

### Legacy BIOS

GRUB (`grub-pc`, as installed by Devuan's installer) boots the kernel,
nothing to install. On a GPT disk (GRUB in a "BIOS boot"
partition), some BIOSes, e.g. Fujitsu PRIMERGY ones, only list the disk as
bootable when the protective MBR is marked active and the BIOS boot
partition has the "Legacy BIOS Bootable" attribute. Set both (here
partition 1 of `/dev/sda`):

```
sudo parted /dev/sda disk_set pmbr_boot on
sudo parted /dev/sda set 1 legacy_boot on
sudo parted /dev/sda print           # Disk Flags: pmbr_boot; 1 … bios_grub, legacy_boot
```

Don't use `parted … set 1 boot on` on a GPT disk: it turns the partition
into an EFI System partition, which such a BIOS doesn't boot from either,
and GRUB can't install to it anymore.

Then:

```
sudo reboot
uname -r                # after the reboot: the -pve kernel
```

### UEFI with Secure Boot

The kernel is signed by Proxmox. Devuan's (Debian's) shim and GRUB only
load kernels signed by Debian, so the machine needs Proxmox's shim (signed
by Microsoft, trusting Proxmox's key) and GRUB (signed by Proxmox), as on
Proxmox VE. The disk needs an EFI System partition (Devuan's installer
creates one when it was booted in UEFI mode).

```
echo "grub-efi-amd64 grub2/force_efi_extra_removable boolean true" | sudo debconf-set-selections
sudo apt install -y grub-efi-amd64 proxmox-secure-boot-support
```

`grub-efi-amd64` replaces `grub-pc` if that's installed (a machine
installed in legacy BIOS mode); installing them runs `grub-install` and
`update-grub`. GRUB goes into the EFI System partition's directory
`EFI/devuan` (`EFI/proxmox` once proxmox-ve is installed, step 5: it sets
`GRUB_DISTRIBUTOR` "Proxmox VE"), with a UEFI boot entry of that name,
and, with the debconf setting, also into the fallback path `EFI/BOOT`,
which firmware boots without a boot entry.

Check:

```
apt-cache policy shim-signed grub-efi-amd64-signed   # the +pmx versions installed
sudo efibootmgr                                      # the new entry first in BootOrder
```

On a GPT disk that had the legacy BIOS flags above, clear the protective
MBR's active flag: with it, UEFI firmware (e.g. Fujitsu PRIMERGY's) takes
the disk for an MBR disk and doesn't find the EFI System partition.

```
sudo parted /dev/sda disk_set pmbr_boot off
```

Then reboot, turn on Secure Boot (and off CSM/legacy boot) in the firmware
setup, and after the reboot:

```
mokutil --sb-state      # SecureBoot enabled
uname -r                # the -pve kernel
```

The same packages boot with Secure Boot off too. Kernels signed by Debian
don't boot with Proxmox's shim under Secure Boot; no machine owner key
(MOK) enrollment is needed for Proxmox's.

## 5. Install Proxmox VE

The hostname must resolve to the machine's LAN address: pmxcfs (pve-cluster)
refuses to start when it resolves to a loopback address only, as with the
`127.0.1.1` entry of a default installation, and the installation fails
("Unable to resolve node name … to a non-loopback IP address"). The address
must not change, so give the machine a static one (or a fixed DHCP lease).

```
ip -4 addr                       # the machine's LAN address
```

Replace the `127.0.1.1` entry in `/etc/hosts`, with your address and domain:

```
IP=192.168.1.50                  # the machine's LAN address
FQDN=$(hostname).example.lan     # the hostname with your domain
sudo sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
echo "$IP $FQDN $(hostname)" | sudo tee -a /etc/hosts
getent hosts "$(hostname)"       # must show the LAN address
```

corosync comes from `/srv/proxmox-devuan-repo`, without a configuration:
its init script is enabled, but doesn't start corosync until the node is
part of a cluster (`pvecm create`/`add` write
`/etc/corosync/corosync.conf`).

Install a mail transport and time synchronization (Proxmox VE needs
both: notifications are sent by mail, and its login tickets and the cluster
need a correct clock), then Proxmox VE:

```
sudo apt install postfix chrony
sudo apt install proxmox-ve ksm-control-daemon
dpkg --audit                     # empty when everything is configured
sudo update-grub
```

ksm-control-daemon (KSM tuning, `ksmtuned`) is installed explicitly: as in
Proxmox's repository, no package depends on it or recommends it. proxmox-ve's
`/etc/default/grub.d/proxmox-ve.cfg` names the boot menu entries "Proxmox
VE" and disables os-prober; `update-grub` applies it.

If the installation failed on pve-cluster because of the hostname, fix
`/etc/hosts` as above, then finish it with:

```
sudo apt -f install
```

pmxcfs refuses to mount on a non-empty `/etc/pve` ("fuse: mountpoint is
not empty"), which happens when something wrote there while it wasn't
running; move such files aside (look at them first):

```
sudo rc-service pve-cluster stop; sudo pkill pmxcfs
sudo ls -la /etc/pve
sudo mkdir -p /root/etc-pve.stray
sudo find /etc/pve -mindepth 1 -maxdepth 1 -exec mv {} /root/etc-pve.stray/ \;
sudo rc-service pve-cluster start
for s in pvedaemon pveproxy spiceproxy pvestatd pvescheduler; do sudo rc-service $s restart; done
sudo pvesh get /cluster/status                  # the standalone node, online
```

Installing ifupdown2 (which replaces ifupdown) reloads the network
configuration and may report `eth0: dhclient: timeout failed to detect new
ip addresses` as the address is already assigned; the address stays. It
also writes `/etc/network/interfaces.new`, applied at the next reboot:
check it, e.g. for the static address and the `lo` lines. If `lo` went
down (pvedaemon: "Cannot assign requested address"), `sudo ip link set lo up`
and restart the daemons:

```
for s in pve-cluster pvedaemon pveproxy spiceproxy pvestatd pvescheduler; do sudo rc-service $s restart; done
```

ifupdown2 replaces ifupdown; its configuration files stay, remove them
with `sudo apt purge ifupdown`.

lxc-pve replaces Devuan's lxc and liblxc. Where Devuan's lxc had been
installed, `/etc/init.d/lxc` and `/etc/init.d/lxc-net` may be left with mode
644; make them executable:

```
sudo chmod 755 /etc/init.d/lxc /etc/init.d/lxc-net
```

## 6. Verification

- `dpkg --audit` is clean.
- `sudo rc-service <name> status` for pve-cluster, pvedaemon, pveproxy,
  spiceproxy, pvestatd, pvescheduler, pve-firewall, pvefw-logger,
  pve-ha-crm, pve-ha-lrm, watchdog-mux, pve-lxc-syscalld, qmeventd, lxc,
  lxcfs, ksmtuned.
- `https://<host>:8006` answers.
- `sudo pvesh get /nodes/<node>/services` reports the services.
