# Omarchy KVM Manager

KVM/QEMU VM manager for the [Omarchy](https://omarchy.org) Quattro bar — `qemu:///system` via `libvirt`/`virsh`.

![KVM Manager panel](preview.png)

## Features

- **Live VM list** — `virsh list --all --title` + `dominfo` polling every 3s, badge `running/total` on bar (`󰢻`)
- **Lifecycle** — Start / Shutdown (graceful) / Force off (`destroy`) / Reboot / Suspend / Resume / Autostart toggle
- **Console** — `virt-viewer` / `remote-viewer` / `virt-manager --show-domain-console` (SPICE/VNC)
- **Snapshots** — Create / List / Revert / Delete (`virsh snapshot-*`)
- **Network** — `default` NAT `virbr0` status + `net-start` / `net-autostart`
- **Details** — vCPU, RAM, OS, firmware (BIOS/UEFI `edk2-ovmf`), TPM (`swtpm`), autostart, snapshots, `domifaddr` IP
- **No secrets** — local-only `virsh`, no passwords stored, no telemetry

## Installation

```bash
omarchy plugin add https://github.com/tug-benson/omarchy-kvm --enable
```

Or symlink for development:

```bash
ln -s /path/to/omarchy-kvm ~/.config/omarchy/plugins/io.github.tug-benson.omarchy-kvm
omarchy-shell shell rescanPlugins
```

Remove:

```bash
omarchy plugin remove io.github.tug-benson.omarchy-kvm
```

## Dependencies

All **manual** via `pacman` — no auto-install:

```bash
sudo pacman -S qemu-full virt-manager virt-viewer libvirt dnsmasq edk2-ovmf swtpm iptables-nft dmidecode
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt $USER  # then logout/login
sudo virsh net-start default && sudo virsh net-autostart default
```

See `INSTALL.md` for full Arch setup (bridge `br0`, nested virt, troubleshooting).

- `qemu-full` + `libvirt` + `virsh` — hypervisor
- `virt-manager` / `virt-viewer` (`remote-viewer`) — console
- `dnsmasq` + `iptables-nft` + `edk2-ovmf` + `swtpm` + `dmidecode` — NAT/UEFI/TPM

## Usage

1. Click `󰢻` in bar → panel opens.
2. Search / filter `All / Running / Off / Paused`.
3. Row actions: `▶ Start` `⏸ Suspend` `⏹ Shutdown` `↻ Reboot` `󰍉 Console` + overflow `Force off`, `Autostart`, `Snapshots`.
4. Expanded detail: `dominfo`, IPs (`domifaddr`), snapshot list + `Create snapshot`.
5. Network section: `default` status + `Start`/`Autostart`.

## Security

- Runs as user in `libvirt` group, no `sudo` inside plugin. `virsh` validates VM names (`^[a-zA-Z0-9._-]+$`, ≤100 chars).
- No remote `qemu+ssh` in v1, no password storage, `settings.json` (`0600`) only if needed.
- Before publish: `grep -R` for homelab data.

## Development

```bash
omarchy plugin validate ~/.config/omarchy/plugins/io.github.tug-benson.omarchy-kvm
qmllint -I "$OMARCHY_PATH/shell" ~/.config/omarchy/plugins/io.github.tug-benson.omarchy-kvm/*.qml
omarchy-shell shell summon io.github.tug-benson.omarchy-kvm '{}'
```

## License

MIT — see `LICENSE`.
