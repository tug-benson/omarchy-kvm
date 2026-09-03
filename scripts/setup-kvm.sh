#!/usr/bin/env bash
# Omarchy KVM — idempotent setup script (Arch/Omarchy)
# Usage: sudo ./scripts/setup-kvm.sh [--daemon libvirtd|modular] [--no-network]
# Safe to re-run. Requires sudo for systemctl/usermod/virsh net-*.
set -euo pipefail

DAEMON="libvirtd"
SETUP_NETWORK=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --daemon) DAEMON="$2"; shift 2;;
    --no-network) SETUP_NETWORK=0; shift;;
    -h|--help) echo "Usage: $0 [--daemon libvirtd|modular] [--no-network]"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

log() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m✔\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m!\033[0m %s\n" "$*" >&2; }

need_cmd() { command -v "$1" &>/dev/null || { warn "missing command: $1"; return 1; }; }

log "1/5 Check hardware virtualization"
if grep -qE 'vmx|svm' /proc/cpuinfo; then
  grep -m1 -E 'vmx|svm' /proc/cpuinfo | tr -s ' ' | head -c 200; echo
  ok "CPU virtualization flag present (svm/vmx)"
else
  warn "No vmx/svm flag — enable VT-x/AMD-V in BIOS/UEFI"
fi
if lsmod | grep -q kvm; then ok "kvm module loaded: $(lsmod | grep kvm | head -n1)"; else warn "kvm not loaded — modprobe kvm_amd/kvm_intel"; fi
if [[ -f /sys/module/kvm_amd/parameters/nested ]]; then echo "nested (kvm_amd): $(cat /sys/module/kvm_amd/parameters/nested)"; fi
if [[ -f /sys/module/kvm_intel/parameters/nested ]]; then echo "nested (kvm_intel): $(cat /sys/module/kvm_intel/parameters/nested)"; fi

log "2/5 Install packages (pacman --needed, idempotent)"
if command -v pacman &>/dev/null; then
  sudo pacman -S --needed --noconfirm \
    qemu-full virt-manager virt-viewer libvirt \
    dnsmasq edk2-ovmf swtpm iptables-nft dmidecode || warn "pacman install failed"
  ok "packages ensured"
else
  warn "pacman not found, skip install"
fi

log "3/5 Enable libvirt daemon ($DAEMON)"
if [[ "$DAEMON" == "modular" ]]; then
  sudo systemctl enable --now virtqemud.socket || warn "virtqemud.socket enable failed"
  sudo systemctl enable --now virtnetworkd.socket || warn "virtnetworkd.socket enable failed"
  sudo systemctl enable --now virtstoraged.socket || true
  sudo systemctl enable --now virtnodedevd.socket || true
else
  sudo systemctl enable --now libvirtd || warn "libvirtd enable failed (try --daemon modular)"
fi
# show status without paging
systemctl is-active libvirtd 2>/dev/null && ok "libvirtd active" || echo "libvirtd: $(systemctl is-active libvirtd 2>&1 || true)"
systemctl is-active virtqemud.socket 2>/dev/null && ok "virtqemud.socket active" || true
systemctl is-active virtqemud.service 2>/dev/null && ok "virtqemud active" || true

log "4/5 User groups"
TARGET_USER="${SUDO_USER:-$USER}"
if ! id -nG "$TARGET_USER" | grep -qw libvirt; then
  sudo usermod -aG libvirt "$TARGET_USER"
  ok "added $TARGET_USER to libvirt (logout/login required)"
  echo "  Current groups (pre-logout): $(id -nG "$TARGET_USER")"
else
  ok "$TARGET_USER already in libvirt"
fi
# kvm group is optional on Arch, but add if desired
if getent group kvm &>/dev/null && ! id -nG "$TARGET_USER" | grep -qw kvm; then
  echo "  (optional) kvm group exists — add with: sudo usermod -aG kvm $TARGET_USER"
fi
echo "  Effective groups this shell: $(groups)"

log "5/5 Default NAT network (virbr0)"
if [[ "$SETUP_NETWORK" == "1" ]]; then
  # wait a moment for daemon socket
  sleep 2
  if sudo virsh net-list --all 2>&1 | grep -q default; then
    if ! sudo virsh net-list --all | grep -q "default.*active"; then
      sudo virsh net-start default || warn "net-start default failed — see journalctl -u libvirtd"
    fi
    sudo virsh net-autostart default || true
    ok "default network ensured"
  else
    warn "default network not defined — defining from /usr/share/libvirt/networks/default.xml"
    if [[ -f /usr/share/libvirt/networks/default.xml ]]; then
      sudo virsh net-define /usr/share/libvirt/networks/default.xml || true
      sudo virsh net-start default || true
      sudo virsh net-autostart default || true
    else
      warn "no default.xml found"
    fi
  fi
  echo "--- virsh net-list --all ---"
  sudo virsh net-list --all || virsh net-list --all || true
  echo "--- virbr0 ---"
  ip a show virbr0 2>&1 | head -n 20 || warn "virbr0 not present yet"
else
  log "skip network (--no-network)"
fi

log "Verify"
virsh --connect qemu:///system list --all 2>&1 | head -n 20 || warn "virsh list failed — check libvirtd + group + logout/login"
virsh --connect qemu:///system capabilities 2>&1 | head -n 5 || true
ok "setup-kvm.sh done — if you were added to libvirt, LOG OUT and LOG BACK IN, then run: virsh list --all && virsh net-list --all && virt-manager"
