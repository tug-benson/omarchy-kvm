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
    dnsmasq edk2-ovmf edk2-aarch64 edk2-riscv64 swtpm iptables-nft dmidecode \
    virt-install qemu-img libosinfo zenity || warn "pacman install failed"
  # Handle virbr0 creation directly: ensure default network is defined and started (common fix for fresh install where virbr0 missing)
  # This is the user-requested direct virbr0 creation after plugin install
  if ! virsh --connect qemu:///system net-list --all 2>&1 | grep -q default; then
    warn "default network not found after package install — will be handled in step 5"
  fi
  # Optional: libguestfs is in extra, bridge-utils is AUR (needs yay/paru)
  sudo pacman -S --needed --noconfirm libguestfs 2>&1 | tail -n 5 || warn "libguestfs not in pacman (try yay -S libguestfs)"
  if command -v yay &>/dev/null; then
    yay -S --needed --noconfirm bridge-utils 2>&1 | tail -n 10 || warn "yay bridge-utils failed"
  elif command -v paru &>/dev/null; then
    paru -S --needed --noconfirm bridge-utils 2>&1 | tail -n 10 || warn "paru bridge-utils failed"
  else
    echo "Note: bridge-utils is AUR (yay/paru) — not in core pacman, skip (install manually: yay -S bridge-utils) if you need bridge networking" | tail -n 5
  fi
  ok "packages ensured"
else
  warn "pacman not found, skip install"
fi

log "3/5 Enable libvirt daemon ($DAEMON) + firewall backend"
# Fix firewall_backend for Arch with iptables-nft/nftables (as per user fix for NAT)
if [[ -f /etc/libvirt/network.conf ]]; then
  if ! grep -q '^\s*firewall_backend\s*=\s*"iptables"' /etc/libvirt/network.conf; then
    if grep -q '^\s*#\s*firewall_backend' /etc/libvirt/network.conf || ! grep -q 'firewall_backend' /etc/libvirt/network.conf; then
      echo 'firewall_backend = "iptables"' | sudo tee -a /etc/libvirt/network.conf >/dev/null && ok "Set firewall_backend = iptables in /etc/libvirt/network.conf (NAT fix)"
      # Need to restart daemons after changing backend
      NEED_RESTART=1
    fi
  else
    ok "firewall_backend already iptables"
  fi
fi
# UFW fix (scoped): allow forwarding ONLY for the libvirt NAT bridge.
# Do NOT change the global DEFAULT_FORWARD_POLICY from DROP to ACCEPT and do
# NOT enable net.ipv4.ip_forward globally via sysctl.d — that would permit
# forwarding beyond the intended libvirt NAT network and weaken the host
# firewall for other interfaces. Instead keep the DROP default and add UFW
# route rules limited to virbr0 / 192.168.122.0/24, so only libvirt guest
# traffic is forwarded. ip_forward itself is enabled through UFW's own
# sysctl.conf (applied by UFW on reload); the filter stays scoped because
# the default forward policy remains DROP.
if command -v ufw &>/dev/null && [[ -f /etc/default/ufw ]]; then
  if grep -q 'DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw; then
    warn "UFW DEFAULT_FORWARD_POLICY is ACCEPT (forwards on ALL interfaces). For a scoped libvirt-only setup, restore DROP and rely on the virbr0 route rules below:"
    echo "  sudo sed -i 's/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/DEFAULT_FORWARD_POLICY=\"DROP\"/' /etc/default/ufw && sudo ufw reload" | tail -n 5
  else
    ok "UFW DEFAULT_FORWARD_POLICY stays at DROP (scoped, not global ACCEPT)"
  fi
  # Route rules scoped to the libvirt bridge (idempotent — skip if present)
  if sudo ufw status 2>/dev/null | grep -q "on virbr0"; then
    ok "UFW virbr0 forward rules already present (scoped to 192.168.122.0/24)"
  else
    sudo ufw route allow in on virbr0 from 192.168.122.0/24 2>&1 | tail -n 3 || warn "ufw route allow in on virbr0 failed"
    sudo ufw route allow out on virbr0 to 192.168.122.0/24 2>&1 | tail -n 3 || warn "ufw route allow out on virbr0 failed"
    ok "Added UFW forward rules scoped to virbr0 192.168.122.0/24 (default policy untouched)"
  fi
  # Let UFW enable the kernel forward knob via its own config (only takes
  # effect when UFW runs; filtering still limited by DROP + scoped rules)
  if [[ -f /etc/ufw/sysctl.conf ]] && grep -q '#net/ipv4/ip_forward=1' /etc/ufw/sysctl.conf; then
    sudo sed -i 's|#net/ipv4/ip_forward=1|net/ipv4/ip_forward=1|' /etc/ufw/sysctl.conf && ok "Enabled net.ipv4.ip_forward in /etc/ufw/sysctl.conf (UFW-managed)" || true
  fi
  sudo ufw reload 2>&1 | tail -n 5 || true
else
  echo "Note: UFW not found — no firewall changes made. If guests get no network, allow forwarding scoped to virbr0 only (never set a global ACCEPT forward policy):" | tail -n 5
  echo "  sudo ufw route allow in on virbr0 from 192.168.122.0/24 && sudo ufw route allow out on virbr0 to 192.168.122.0/24 && sudo ufw reload" | tail -n 5
fi
# Check (do not change): libvirt NAT needs ip_forward=1 at runtime. If it is
# off, point at the scoped fix above instead of forcing it globally here.
if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 1)" != "1" ]]; then
  warn "net.ipv4.ip_forward is 0 — libvirt NAT needs it. Enable it via UFW (see above) or scoped sysctl, not a global ACCEPT policy. After enabling, restart virtnetworkd/libvirtd and net-start default."
fi

if [[ "$DAEMON" == "modular" ]]; then
  sudo systemctl enable --now virtqemud.socket || warn "virtqemud.socket enable failed"
  sudo systemctl enable --now virtnetworkd.socket || warn "virtnetworkd.socket enable failed"
  sudo systemctl enable --now virtstoraged.socket || true
  sudo systemctl enable --now virtnodedevd.socket || true
  sudo systemctl enable --now virtinterfaced.socket 2>/dev/null || true
  sudo systemctl enable --now virtsecretd.socket 2>/dev/null || true
  sudo systemctl enable --now virtproxyd.socket 2>/dev/null || true
  # Also enable the services themselves for autostart
  sudo systemctl enable --now virtqemud.service 2>/dev/null || true
  sudo systemctl enable --now virtnetworkd.service 2>/dev/null || true
else
  sudo systemctl enable --now libvirtd || warn "libvirtd enable failed (try --daemon modular)"
fi
# Restart daemons if we changed firewall_backend
if [[ "${NEED_RESTART:-0}" == "1" ]]; then
  log "Restarting libvirt daemons after firewall_backend change..."
  if [[ "$DAEMON" == "modular" ]]; then
    sudo systemctl restart virtnetworkd 2>&1 | tail -n 5 || true
    sudo systemctl restart virtqemud 2>&1 | tail -n 5 || true
  else
    sudo systemctl restart libvirtd 2>&1 | tail -n 5 || true
  fi
  sleep 2
fi
# show status without paging
systemctl is-active libvirtd 2>/dev/null && ok "libvirtd active" || echo "libvirtd: $(systemctl is-active libvirtd 2>&1 || true)"
systemctl is-active virtqemud.socket 2>/dev/null && ok "virtqemud.socket active" || true
systemctl is-active virtqemud.service 2>/dev/null && ok "virtqemud active" || true
systemctl is-active virtnetworkd.service 2>/dev/null && ok "virtnetworkd active" || echo "virtnetworkd: $(systemctl is-active virtnetworkd 2>&1 || true)"

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
  sleep 2
  # Ensure default network is defined (handle both monolithic and modular daemons)
  # Use explicit URI for modular
  VIRSH="virsh --connect qemu:///system"
  if ! sudo $VIRSH net-list --all 2>&1 | grep -q default; then
    warn "default network not defined — trying to define"
    # Try common locations
    for f in /etc/libvirt/qemu/networks/default.xml /usr/share/libvirt/networks/default.xml; do
      if [[ -f "$f" ]]; then
        sudo $VIRSH net-define "$f" 2>&1 | tail -n 5 || true
        break
      fi
    done
    # If still not found, create a minimal default network (as per libvirt docs)
    if ! sudo $VIRSH net-list --all 2>&1 | grep -q default; then
      warn "Creating minimal default network (virbr0 192.168.122.0/24)"
      tmp_net_xml=$(mktemp)
      # mktemp creates 0600 O_EXCL and does not follow symlinks — avoids
      # predictable /tmp/default-net.xml symlink overwrite when run via sudo
      cat > "$tmp_net_xml" <<'XML'
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp><range start='192.168.122.2' end='192.168.122.254'/></dhcp>
  </ip>
</network>
XML
      sudo $VIRSH net-define "$tmp_net_xml" 2>&1 | tail -n 5 || true
      rm -f "$tmp_net_xml"
    fi
  fi
  # Now ensure it is active (handle case where it was defined but not started due to firewall_backend change)
  # Use word boundary to avoid matching "inactive" as "active" (common bug on Mac where default is inactive)
  if sudo $VIRSH net-list --all 2>&1 | grep -qE "default\s+active\b"; then
    ok "default network already active"
  else
    # Try to start, if fails due to already active but not listed, try destroy/start cycle (as user did for firewall_backend fix)
    if ! sudo $VIRSH net-start default 2>&1 | tail -n 5; then
      warn "net-start failed, trying destroy/start cycle (firewall_backend fix)"
      sudo $VIRSH net-destroy default 2>&1 | tail -n 5 || true
      sleep 1
      # For modular, ensure virtnetworkd is running
      sudo systemctl restart virtnetworkd 2>&1 | tail -n 5 || true
      sudo systemctl restart virtqemud 2>&1 | tail -n 5 || true
      sleep 2
      sudo $VIRSH net-start default 2>&1 | tail -n 5 || warn "net-start still failed — check journalctl -u virtnetworkd"
    fi
  fi
  sudo $VIRSH net-autostart default 2>&1 | tail -n 5 || true
  ok "default network ensured"
  echo "--- virsh net-list --all ---"
  sudo $VIRSH net-list --all || virsh net-list --all || true
  echo "--- virbr0 ---"
  ip a show virbr0 2>&1 | head -n 20 || warn "virbr0 not present yet"
  echo "--- iptables NAT (should show MASQUERADE for 192.168.122.0/24) ---"
  sudo iptables -t nat -L -n -v 2>&1 | grep -A2 "192.168.122" | head -n 20 || echo "no iptables NAT rules (may be using nftables, check 'nft list ruleset | grep LIBVIRT')"
  echo "--- nft ruleset LIBVIRT (if using nftables) ---"
  sudo nft list ruleset 2>&1 | grep -A10 "LIBVIRT_PRT" | head -n 20 || true
else
  log "skip network (--no-network)"
fi

log "Verify"
virsh --connect qemu:///system list --all 2>&1 | head -n 20 || warn "virsh list failed — check libvirtd + group + logout/login"
virsh --connect qemu:///system capabilities 2>&1 | head -n 5 || true
ok "setup-kvm.sh done — if you were added to libvirt, LOG OUT and LOG BACK IN, then run: virsh list --all && virsh net-list --all && virt-manager"
