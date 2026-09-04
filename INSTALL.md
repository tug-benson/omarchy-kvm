# Omarchy KVM — Installation & Test Procedure

> Arch Linux (Omarchy) — KVM/QEMU/libvirt setup for the `io.github.tug-benson.omarchy-kvm` plugin.
> Based on https://computingforgeeks.com/install-kvm-arch-linux/ + verified on this host (AMD EPYC, `kvm_amd`, nested=1, 2026-09-03).

## 0. Prerequisites

- Arch / Omarchy bare-metal with hardware virtualization enabled in BIOS/UEFI (AMD-V / VT-x).
- `sudo` access, ≥4 GB RAM, `btrfs`/`ext4` on NVMe recommended.

Check CPU flags:

```bash
grep -cE 'vmx|svm' /proc/cpuinfo   # >0 = OK (this host: 16, svm)
lsmod | grep kvm                    # kvm_amd + kvm should appear
cat /sys/module/kvm_amd/parameters/nested  # 1 = nested enabled
# Intel alternative:
cat /sys/module/kvm_intel/parameters/nested
```

This host already shows `kvm_amd` loaded and `nested=1` — no BIOS change needed.

## 1. Install packets

All in official Arch repos — already installed on this host but rerunnable:

```bash
sudo pacman -S --needed \
  qemu-full virt-manager virt-viewer libvirt \
  dnsmasq edk2-ovmf edk2-aarch64 edk2-riscv64 \
  swtpm iptables-nft dmidecode

# optional but useful
sudo pacman -S --needed bridge-utils libguestfs
```

What each does:

| Package | Purpose |
|---|---|
| `qemu-full` | Full QEMU (x86_64, ARM, etc.) + `qemu-img`, `qemu-system-x86_64` |
| `virt-manager` | GTK GUI to create/manage VMs |
| `virt-viewer` / `remote-viewer` | SPICE/VNC console |
| `libvirt` | Daemon + `virsh` API (monolithic `libvirtd` or modular `virtqemud`) |
| `dnsmasq` | DHCP/DNS for NAT `default` network |
| `edk2-ovmf` | UEFI firmware (`/usr/share/edk2-ovmf/x64/OVMF_CODE.fd`) |
| `swtpm` | TPM 2.0 emulator (Windows 11) |
| `iptables-nft` | NAT firewall backend |
| `dmidecode` | Fixes virt-manager `libvirtd` journal error |

Verify:

```bash
pacman -Q | grep -E 'qemu|libvirt|virt-manager|dnsmasq|edk2|swtpm'
qemu-system-x86_64 --version
virsh --version
```

## 2. Enable libvirt daemon

Arch offers **legacy monolithic** vs **modular**. The guide uses legacy; both work. Pick one:

### Option A — Legacy (recommended for simple NAT, matches the guide)

```bash
sudo systemctl enable --now libvirtd
sudo systemctl status libvirtd        # active (running)
sudo systemctl status libvirtd.socket # triggers on demand
```

`libvirtd` pulls `virtlogd.socket` + `virtlockd.socket` automatically.

### Option B — Modular (modern, systemd sockets)

```bash
sudo systemctl enable --now virtqemud.socket
sudo systemctl enable --now virtnetworkd.socket
sudo systemctl enable --now virtstoraged.socket
sudo systemctl enable --now virtnodedevd.socket
# then virsh --connect qemu:///system works via virtqemud-sock
```

> On this host both `libvirtd.service` and `virtqemud.service` are `inactive (dead)` and sockets `disabled` — run **Option A** to start.

Idempotent helper script (also in `scripts/setup-kvm.sh`):

```bash
./scripts/setup-kvm.sh --daemon libvirtd   # or --daemon modular
```

## 3. Add user to `libvirt` group

```bash
sudo usermod -aG libvirt $USER
# optional: sudo usermod -aG kvm $USER   # kvm group exists (991) but libvirt is sufficient on Arch
groups          # before logout: user wheel
# log out + log back in (Hyprland: Super+Alt+Q → login) or:
newgrp libvirt  # temporary for current shell
groups          # after: user wheel libvirt
id $USER
```

Without this, `virsh list --all` fails with `Failed to connect socket to '/run/libvirt/libvirt-sock': Permission denied`.

## 4. Default NAT network

Creates `virbr0` `192.168.122.0/24` via dnsmasq + iptables-nft:

```bash
# as your user after group fix, or with sudo before:
sudo virsh net-start default
sudo virsh net-autostart default

virsh net-list --all
#  Name      State    Autostart   Persistent
#  default   active   yes         yes

ip a show virbr0
# inet 192.168.122.1/24 ...

# if missing:
sudo virsh net-define /usr/share/libvirt/networks/default.xml
```

If it fails: `sudo journalctl -u libvirtd -n 50` (or `journalctl -u virtnetworkd` for modular), check `dnsmasq` and `iptables-nft` installed, and that no other dnsmasq on `192.168.122.0/24` conflicts.

**Troubleshooting NAT (no VM IP, `virsh net-list` empty or `iptables -t nat` empty)** — as encountered on Arch with `iptables-nft`/`nftables` + `UFW` (see https://blog.stephane-robert.info/docs/virtualiser/type1/kvm/reseau/):

```bash
# 1. Check network exists and firewall backend
virsh --connect qemu:///system net-info default  # Active: yes / Bridge: virbr0 ?
sudo nft list ruleset | grep -A5 libvirt   # should show table ip/nat LIBVIRT_PRT with MASQUERADE 192.168.122.0/24
sudo iptables -t nat -L -n -v | grep 192.168.122  # alternative check
cat /etc/libvirt/network.conf  # should be firewall_backend = "iptables" on Arch with UFW/nft

# 2. If empty / backend is nftables but host uses iptables-nft, fix it:
echo 'firewall_backend = "iptables"' | sudo tee /etc/libvirt/network.conf
# For UFW users: UFW sets FORWARD DROP which blocks virbr0
grep DEFAULT_FORWARD_POLICY /etc/default/ufw  # if DROP, change to ACCEPT
sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
sudo sed -i 's/#net\/ipv4\/ip_forward=1/net\/ipv4\/ip_forward=1/' /etc/ufw/sysctl.conf
sudo ufw reload

# 3. Restart daemons (handle both monolithic and modular)
# Monolithic:
sudo systemctl restart libvirtd
# Modular (Arch default as of 2026, with virtqemud/virtnetworkd):
sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket virtinterfaced.socket virtnodedevd.socket virtsecretd.socket virtproxyd.socket
sudo systemctl restart virtnetworkd
sudo systemctl restart virtqemud
sleep 2
sudo virsh --connect qemu:///system net-destroy default; sudo virsh --connect qemu:///system net-start default
virsh --connect qemu:///system net-list --all  # should be active yes
sudo nft list ruleset | grep -A10 "table ip nat"  # should show LIBVIRT_PRT MASQUERADE
ping -c 2 192.168.122.1  # host's virbr0
# VM should now get 192.168.122.x via DHCP (check virsh domifaddr <vm> --source lease)
```

Default XML location (after define):
```
/etc/libvirt/qemu/networks/default.xml
/etc/libvirt/qemu/networks/autostart/default.xml -> ../default.xml
/var/lib/libvirt/dnsmasq/default.conf
```

## 5. Verify launch

```bash
virsh --connect qemu:///system list --all
virsh --connect qemu:///system net-list --all
virsh --connect qemu:///system capabilities | head -n 40
virt-manager &   # should show QEMU/KVM Connected
```

Create a test VM (optional):

```bash
# qcow2 in libvirt pool
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/test-alpine.qcow2 8G
# then File > New Virtual Machine > Local ISO > Alpine/CachyOS ISO > 2048 MB / 2 vCPU / qcow2 / UEFI OVMF if needed
# or via virsh:
virt-install --name test-alpine --ram 2048 --vcpus 2 \
  --disk path=/var/lib/libvirt/images/test-alpine.qcow2,size=8 \
  --os-variant archlinux --network network=default --graphics spice \
  --cdrom ~/Downloads/alpine.iso --boot uefi
```

Quick virsh lifecycle test (after at least one VM exists):

```bash
virsh list --all
virsh dominfo test-alpine
virsh start test-alpine
virsh shutdown test-alpine   # graceful
virsh destroy test-alpine    # force
virsh reboot test-alpine
virsh suspend test-alpine && virsh resume test-alpine
virsh autostart test-alpine && virsh autostart --disable test-alpine
virsh snapshot-create-as test-alpine snap1 --description "before update"
virsh snapshot-list test-alpine
virsh snapshot-revert test-alpine snap1
```

Console:

```bash
virt-viewer --connect qemu:///system test-alpine &
# or
remote-viewer spice://localhost:5900 &
```

## 6. Optional: Bridge networking (LAN-visible VMs)

For VMs needing DHCP from physical router (vs NAT):

```bash
# NetworkManager (Omarchy default):
nmcli connection add type bridge con-name br0 ifname br0
nmcli connection add type bridge-slave con-name br0-port1 ifname enp1s0 master br0
nmcli connection up br0
# replace enp1s0 with your iface: ip link

# ip route alternative:
sudo ip link add br0 type bridge
sudo ip link set br0 up
sudo ip link set enp1s0 master br0

# then in virt-manager: VM > Details > NIC > Network source: Bridge device, Device: br0
```

## 7. Optional: Nested virtualization (already enabled here)

```bash
# AMD (this host):
echo "options kvm_amd nested=1" | sudo tee /etc/modprobe.d/kvm-amd.conf
# Intel:
echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-intel.conf
sudo reboot
cat /sys/module/kvm_amd/parameters/nested  # 1 = OK
```

## 8. Omarchy plugin dev link

```bash
# symlink for live reload (as done for omarchy-openvpn / remmina):
ln -s /path/to/omarchy-kvm ~/.config/omarchy/plugins/io.github.tug-benson.omarchy-kvm
omarchy-shell shell rescanPlugins
omarchy plugin list --json | jq --arg id "io.github.tug-benson.omarchy-kvm" '.[] | select(.id==$id)'

# validate (after manifest+QML exist):
omarchy plugin validate ~/.config/omarchy/plugins/io.github.tug-benson.omarchy-kvm
qmllint -I "$OMARCHY_PATH/shell" ~/.config/omarchy/plugins/io.github.tug-benson.omarchy-kvm/*.qml
```

## 9. Troubleshooting

| Symptom | Fix |
|---|---|
| `Cannot access storage file — Permission denied` | Move ISO/qcow2 to `/var/lib/libvirt/images/` + `sudo chown qemu:qemu` or fix parent perms; check `libvirt` group |
| `Network 'default' is not active` | `sudo virsh net-start default && sudo virsh net-autostart default`; install `dnsmasq` + `iptables-nft` |
| `Not Connected` in virt-manager | `sudo systemctl status libvirtd` + `groups` contains `libvirt` + logout/login |
| Slow VM | Use `virtio` disk/net, `host-passthrough` CPU, install `virtio-win` for Windows |
| `Failed to initialize a valid firewall backend` | `sudo pacman -S iptables-nft` + reboot; see https://computingforgeeks.com/solve-libvirt-failed-to-initialize-a-valid-firewall-backend-on-arch-linux/ |
| `dmidecode` missing error in journal | `sudo pacman -S dmidecode` (already installed) |

## 10. References

- Guide: https://computingforgeeks.com/install-kvm-arch-linux/
- Arch Wiki KVM: https://wiki.archlinux.org/title/KVM
- Arch Wiki libvirt: https://wiki.archlinux.org/title/Libvirt
- Omarchy plugin dev: https://plugins.omarchy.org/develop.html
- Shell README: https://github.com/basecamp/omarchy/blob/quattro/shell/README.md
- Built-in plugins: https://github.com/basecamp/omarchy/tree/quattro/shell/plugins
