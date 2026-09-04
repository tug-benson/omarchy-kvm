#!/usr/bin/env bash
set -euo pipefail

# ova_to_qcow2.sh - Non-interactive OVA/VMDK to qcow2 conversion + KVM VM creation
# Adapted for Omarchy panel (no read -p, CLI args, set -euo pipefail, autodetect, temp dir owned by user)
# Usage: ova_to_qcow2.sh --file <path> --vm-name <name> --memory <MB> --vcpus <n> --pool-path </path> --os-variant <id> [--no-create]
# --no-create: only convert, do not create VM
# Dependencies: tar, gzip, qemu-img, virsh, virt-install, zenity (for UI picker, not for script), df

usage() {
    echo "Usage: $0 --file <path> --vm-name <name> --memory <MB> --vcpus <n> --pool-path </path> --os-variant <id> [--no-create]" >&2
    echo "  --file        Path to OVA, VMDK or VMDK.GZ file" >&2
    echo "  --vm-name     Name for the new VM (alnum, ., _, -)" >&2
    echo "  --memory      RAM in MB (e.g., 2048)" >&2
    echo "  --vcpus       Number of vCPUs (e.g., 2)" >&2
    echo "  --pool-path   Target pool directory (e.g., /var/lib/libvirt/images or /home/user/VMs)" >&2
    echo "  --os-variant  OS variant id (e.g., generic, debian12, ubuntu24.04) - see osinfo-query" >&2
    echo "  --no-create   Only convert to qcow2, do not create VM" >&2
    exit 2
}

# Default values
FILE=""
VM_NAME=""
MEMORY=""
VCPUS=""
POOL_PATH=""
OS_VARIANT="generic"
NO_CREATE=0

# Parse CLI args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file) FILE="$2"; shift 2 ;;
        --vm-name) VM_NAME="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --vcpus) VCPUS="$2"; shift 2 ;;
        --pool-path) POOL_PATH="$2"; shift 2 ;;
        --os-variant) OS_VARIANT="$2"; shift 2 ;;
        --no-create) NO_CREATE=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

# Validation
if [[ -z "$FILE" ]]; then echo "Error: --file is required" >&2; usage; fi
if [[ ! -f "$FILE" ]]; then echo "Error: File not found: $FILE" >&2; exit 1; fi
if [[ $NO_CREATE -eq 0 ]]; then
    if [[ -z "$VM_NAME" ]]; then echo "Error: --vm-name is required (unless --no-create)" >&2; usage; fi
    if ! [[ "$VM_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then echo "Error: Invalid VM name: $VM_NAME (allowed: alnum, ., _, -)" >&2; exit 1; fi
    if [[ -z "$MEMORY" ]] || ! [[ "$MEMORY" =~ ^[0-9]+$ ]]; then echo "Error: Invalid --memory: $MEMORY" >&2; exit 1; fi
    if [[ -z "$VCPUS" ]] || ! [[ "$VCPUS" =~ ^[0-9]+$ ]]; then echo "Error: Invalid --vcpus: $VCPUS" >&2; exit 1; fi
    if [[ -z "$POOL_PATH" ]]; then echo "Error: --pool-path is required" >&2; usage; fi
    if [[ ! -d "$POOL_PATH" ]]; then echo "Error: Pool path not found or not a directory: $POOL_PATH" >&2; exit 1; fi
    if [[ -z "$OS_VARIANT" ]]; then OS_VARIANT="generic"; fi
else
    # --no-create: only need file and pool-path for output location
    if [[ -z "$POOL_PATH" ]]; then echo "Error: --pool-path is required (even with --no-create)" >&2; usage; fi
    if [[ ! -d "$POOL_PATH" ]]; then echo "Error: Pool path not found: $POOL_PATH" >&2; exit 1; fi
    # Use file basename for output name if vm-name not provided
    if [[ -z "$VM_NAME" ]]; then
        VM_NAME="$(basename "${FILE%.*}" | tr -dc '[:alnum:]-')"
        VM_NAME=${VM_NAME:-converted}
    fi
fi

# Dependency checks
for cmd in qemu-img virsh; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required command not found: $cmd" >&2
        exit 1
    fi
done
if [[ $NO_CREATE -eq 0 ]] && ! command -v virt-install >/dev/null 2>&1; then
    echo "Error: virt-install not found (install virtinst)" >&2
    exit 1
fi

# Disk space check (need ~2x source size for extraction + conversion)
if command -v df >/dev/null 2>&1; then
    SRC_SIZE=$(stat -c%s "$FILE" 2>/dev/null || stat -f%z "$FILE" 2>/dev/null || echo 0)
    if [[ "$SRC_SIZE" -gt 0 ]]; then
        # Use mktemp's parent dir for space check (usually /tmp)
        TMP_PARENT=$(dirname "$(mktemp -u)")
        AVAIL=$(df --output=avail -B1 "$TMP_PARENT" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)
        # Need roughly 2x source + a bit
        NEED=$((SRC_SIZE * 2 + 100*1024*1024))
        if [[ "$AVAIL" -gt 0 && "$AVAIL" -lt "$NEED" ]]; then
            echo "Warning: Low disk space in $TMP_PARENT (avail $(numfmt --to=iec $AVAIL 2>/dev/null || echo $AVAIL), need ~$(numfmt --to=iec $NEED 2>/dev/null || echo $NEED))" >&2
        fi
        # Also check pool path space
        POOL_AVAIL=$(df --output=avail -B1 "$POOL_PATH" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)
        if [[ "$POOL_AVAIL" -gt 0 && "$POOL_AVAIL" -lt "$SRC_SIZE" ]]; then
            echo "Warning: Low disk space in pool $POOL_PATH" >&2
        fi
    fi
fi

# Create temp dir owned by current user (no sudo) - use pool path if /tmp too small
# For large VMDKs (e.g., Kali 15G -> 40G qcow2), /tmp (tmpfs 31G) may be too small
POOL_AVAIL_TMP=$(df --output=avail -B1 "$POOL_PATH" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)
TMP_AVAIL=$(df --output=avail -B1 "/tmp" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)
# If pool has more space than /tmp and is writable, use it for temp
if [[ "$POOL_AVAIL_TMP" -gt "$TMP_AVAIL" ]] && [[ -w "$POOL_PATH" ]]; then
    TEMP_DIR=$(mktemp -d -p "$POOL_PATH" tmp.ova.XXXXXX 2>/dev/null || mktemp -d)
    echo "Using pool path for temp (more space): $TEMP_DIR" | stdbuf -oL cat
else
    TEMP_DIR=$(mktemp -d)
fi
# Ensure cleanup on exit
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
# Make temp dir accessible (in case libvirt needs it, though we avoid sudo)
chmod 755 "$TEMP_DIR" 2>/dev/null || true

echo "Working in temp dir: $TEMP_DIR" | stdbuf -oL cat

# Determine input type and prepare VMDK
VMDK_FILE=""
QCOW2_FILE_NAME="${VM_NAME}.qcow2"
# If --no-create and VM_NAME derived from file, use that
if [[ "$QCOW2_FILE_NAME" == ".qcow2" ]]; then
    QCOW2_FILE_NAME="$(basename "${FILE%.*}").qcow2"
    [[ "$QCOW2_FILE_NAME" == ".qcow2" ]] && QCOW2_FILE_NAME="converted.qcow2"
fi
QCOW2_TEMP_PATH="$TEMP_DIR/$QCOW2_FILE_NAME"

# Autodetect: if file is already .vmdk or .vmdk.gz, skip tar extraction
IS_VMDK=0
IS_VMDK_GZ=0
if [[ "$FILE" == *.vmdk.gz ]]; then IS_VMDK_GZ=1
elif [[ "$FILE" == *.vmdk ]]; then IS_VMDK=1
fi

if [[ $IS_VMDK -eq 1 ]]; then
    echo "Input is already VMDK, skipping OVA extraction..." | stdbuf -oL cat
    # Handle split VMDKs (e.g., kali with -s001.vmdk, -s002.vmdk, etc.)
    VMDK_DIR="$(dirname "$FILE")"
    VMDK_BASE="$(basename "$FILE" .vmdk)"
    SPLIT_FOUND=0
    # Check for any split parts (e.g., *-s*.vmdk) - handle glob safely
    shopt -s nullglob
    for f in "$VMDK_DIR"/"$VMDK_BASE"-s*.vmdk; do
        if [[ "$f" != "$FILE" && -f "$f" ]]; then SPLIT_FOUND=1; break; fi
    done
    if [[ $SPLIT_FOUND -eq 0 ]]; then
        for f in "$VMDK_DIR"/"$VMDK_BASE"*.vmdk; do
            if [[ "$f" != "$FILE" && -f "$f" ]]; then SPLIT_FOUND=1; break; fi
        done
    fi
    shopt -u nullglob
    # Also check via ls for s001 pattern
    if ls "$VMDK_DIR"/"$VMDK_BASE"-s001.vmdk >/dev/null 2>&1; then SPLIT_FOUND=1; fi
    if [[ $SPLIT_FOUND -eq 1 ]]; then
        echo "Detected split VMDK, copying all parts to temp dir..." | stdbuf -oL cat
        # Copy all related VMDK files for this base
        shopt -s nullglob
        cp -- "$VMDK_DIR"/"$VMDK_BASE"*.vmdk "$TEMP_DIR"/ 2>/dev/null || cp -- "$FILE" "$TEMP_DIR"/
        shopt -u nullglob
        VMDK_FILE="$TEMP_DIR/$(basename "$FILE")"
        echo "Copied split VMDK set to $TEMP_DIR" | stdbuf -oL cat
        ls -lh "$TEMP_DIR"/*.vmdk 2>&1 | stdbuf -oL cat || true
    else
        # Single VMDK - use original path directly (avoids copy, handles large files better)
        # Check if original is readable, if not, copy
        if [[ -r "$FILE" ]]; then
            VMDK_FILE="$FILE"
            echo "Using original VMDK path: $VMDK_FILE" | stdbuf -oL cat
        else
            VMDK_FILE="$TEMP_DIR/$(basename "$FILE")"
            cp -- "$FILE" "$VMDK_FILE"
            echo "Copied single VMDK to $VMDK_FILE" | stdbuf -oL cat
        fi
    fi
elif [[ $IS_VMDK_GZ -eq 1 ]]; then
    echo "Input is VMDK.GZ, decompressing..." | stdbuf -oL cat
    VMDK_FILE="$TEMP_DIR/$(basename "${FILE%.gz}")"
    # Use gzip -dc to avoid removing original
    gzip -dc -- "$FILE" > "$VMDK_FILE"
    echo "Decompressed to $VMDK_FILE" | stdbuf -oL cat
else
    # Assume OVA (tar archive)
    echo "Extracting OVA $FILE to $TEMP_DIR..." | stdbuf -oL cat
    if ! tar -tf "$FILE" >/dev/null 2>&1; then
        echo "Warning: File does not appear to be a valid tar archive, trying anyway..." >&2 | stdbuf -oL cat
    fi
    # Use stdbuf for tar progress if possible
    if ! tar -xf "$FILE" -C "$TEMP_DIR" 2>&1 | stdbuf -oL cat; then
        echo "Error: Failed to extract OVA archive" >&2
        exit 1
    fi
    echo "Extraction done, searching for VMDK..." | stdbuf -oL cat
    # Find VMDK (prefer .vmdk.gz, then .vmdk)
    VMDK_FILE=$(find "$TEMP_DIR" -name "*.vmdk.gz" -print -quit 2>/dev/null || true)
    if [[ -n "$VMDK_FILE" && -f "$VMDK_FILE" ]]; then
        echo "Decompressing $VMDK_FILE..." | stdbuf -oL cat
        gunzip -- "$VMDK_FILE"
        VMDK_FILE="${VMDK_FILE%.gz}"
    else
        VMDK_FILE=$(find "$TEMP_DIR" -name "*.vmdk" -print -quit 2>/dev/null || true)
    fi
    if [[ -z "$VMDK_FILE" || ! -f "$VMDK_FILE" ]]; then
        echo "Error: VMDK file not found in OVA archive (searched $TEMP_DIR)" >&2
        echo "Contents of temp dir:" >&2
        ls -R "$TEMP_DIR" >&2 || true
        exit 1
    fi
fi

echo "Found VMDK file: $VMDK_FILE" | stdbuf -oL cat
# Ensure VMDK is readable
if [[ ! -r "$VMDK_FILE" ]]; then
    echo "Error: VMDK file not readable: $VMDK_FILE" >&2
    exit 1
fi

echo "Converting VMDK to QCOW2 at $QCOW2_TEMP_PATH..." | stdbuf -oL cat
# Use stdbuf to ensure line-buffered output
if ! stdbuf -oL qemu-img convert -p -O qcow2 -- "$VMDK_FILE" "$QCOW2_TEMP_PATH" 2>&1 | stdbuf -oL cat; then
    echo "Error: qemu-img convert failed" >&2
    exit 1
fi

if [[ ! -f "$QCOW2_TEMP_PATH" ]]; then
    echo "Error: QCOW2 file not created at $QCOW2_TEMP_PATH" >&2
    exit 1
fi

echo "Conversion successful: $QCOW2_TEMP_PATH ($(du -h "$QCOW2_TEMP_PATH" | cut -f1))" | stdbuf -oL cat

# If --no-create, just move to pool and exit
if [[ $NO_CREATE -eq 1 ]]; then
    FINAL_PATH="$POOL_PATH/$QCOW2_FILE_NAME"
    echo "Moving converted disk to $FINAL_PATH (no-create)..." | stdbuf -oL cat
    # Ensure pool path is writable (user has write rights, avoid sudo)
    if [[ ! -w "$POOL_PATH" ]]; then
        echo "Error: Pool path not writable: $POOL_PATH (check permissions, user needs write access, avoid sudo for conversion)" >&2
        exit 1
    fi
    if [[ -f "$FINAL_PATH" ]]; then
        echo "Warning: $FINAL_PATH already exists, will overwrite" >&2 | stdbuf -oL cat
        rm -f -- "$FINAL_PATH"
    fi
    if ! mv -- "$QCOW2_TEMP_PATH" "$FINAL_PATH"; then
        echo "Error: Failed to move QCOW2 to $FINAL_PATH (check permissions)" >&2
        exit 1
    fi
    # Refresh pool if it's a libvirt pool
    POOL_NAME=$(virsh --connect qemu:///system pool-list --all 2>/dev/null | awk -v path="$POOL_PATH" '
        NR>2 { pool=$1; cmd="virsh --connect qemu:///system pool-dumpxml "pool" 2>/dev/null | grep -q \""path">"path"\""; if (system(cmd)==0) print pool }
    ' | head -n1 || true)
    # Simpler: try to refresh all pools that match path
    for p in $(virsh --connect qemu:///system pool-list --name 2>/dev/null || true); do
        P_PATH=$(virsh --connect qemu:///system pool-dumpxml "$p" 2>/dev/null | grep -oPm1 "(?<=<path>)[^<]+")
        if [[ "$P_PATH" == "$POOL_PATH" ]]; then
            echo "Refreshing pool $p..." | stdbuf -oL cat
            virsh --connect qemu:///system pool-refresh "$p" 2>&1 | stdbuf -oL cat || true
            break
        fi
    done
    echo "Done (no-create): $FINAL_PATH" | stdbuf -oL cat
    exit 0
fi

# --- VM Creation with virt-install (local only, qemu:///system) ---
# Ensure pool path is writable
if [[ ! -w "$POOL_PATH" ]]; then
    echo "Error: Pool path not writable: $POOL_PATH" >&2
    exit 1
fi

FINAL_PATH="$POOL_PATH/$QCOW2_FILE_NAME"
echo "Moving converted disk to $FINAL_PATH..." | stdbuf -oL cat
if [[ -f "$FINAL_PATH" ]]; then
    echo "Warning: $FINAL_PATH already exists, will overwrite" >&2 | stdbuf -oL cat
    rm -f -- "$FINAL_PATH"
fi
if ! mv -- "$QCOW2_TEMP_PATH" "$FINAL_PATH"; then
    echo "Error: Failed to move QCOW2 to $FINAL_PATH" >&2
    exit 1
fi
# Ensure qemu can read it (for /home paths, parent dirs need o+x, file needs o+r)
chmod 644 -- "$FINAL_PATH" 2>/dev/null || true
# For home pools, ensure parent is accessible (best effort, no sudo)
# The pool's dir already has 755 from earlier, but ensure file is readable
# Refresh the pool that owns this path
for p in $(virsh --connect qemu:///system pool-list --name 2>/dev/null || true); do
    P_PATH=$(virsh --connect qemu:///system pool-dumpxml "$p" 2>/dev/null | grep -oPm1 "(?<=<path>)[^<]+")
    if [[ "$P_PATH" == "$POOL_PATH" ]]; then
        echo "Refreshing pool $p..." | stdbuf -oL cat
        virsh --connect qemu:///system pool-refresh "$p" 2>&1 | stdbuf -oL cat || true
        break
    fi
done

echo "Creating KVM VM $VM_NAME (memory $MEMORY MB, vcpus $VCPUS, os-variant $OS_VARIANT)..." | stdbuf -oL cat
# Use stdbuf for virt-install progress
if ! stdbuf -oL virt-install --connect qemu:///system --name "$VM_NAME" --memory "$MEMORY" --vcpus "$VCPUS" --disk "path=$FINAL_PATH,device=disk,bus=virtio" --import --os-variant "$OS_VARIANT" --network network=default,model=virtio --graphics vnc,listen=127.0.0.1 --noautoconsole 2>&1 | stdbuf -oL cat; then
    echo "Error: virt-install failed (see above)" >&2
    echo "Disk is available at: $FINAL_PATH" >&2
    exit 1
fi

echo "----------------------------------------------------------------" | stdbuf -oL cat
echo "VM '$VM_NAME' created successfully." | stdbuf -oL cat
echo "Disk: $FINAL_PATH" | stdbuf -oL cat
echo "Pool: $POOL_PATH" | stdbuf -oL cat
echo "Manage with 'virsh --connect qemu:///system list --all' or virt-manager" | stdbuf -oL cat
echo "----------------------------------------------------------------" | stdbuf -oL cat
