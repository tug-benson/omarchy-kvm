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

# Disk space check — enforced (not just a warning). A compressed OVA can
# be a zip-bomb: small FILE but huge extraction. Check both compressed size
# and, for tar, total uncompressed size (195-203 also re-checks after TEMP_DIR
# is chosen). Fail rather than let tar exhaust the filesystem.
if command -v df >/dev/null 2>&1; then
    SRC_SIZE=$(stat -c%s "$FILE" 2>/dev/null || stat -f%z "$FILE" 2>/dev/null || echo 0)
    if [[ "$SRC_SIZE" -gt 0 ]]; then
        TMP_PARENT=$(dirname "$(mktemp -u)")
        AVAIL=$(df --output=avail -B1 "$TMP_PARENT" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)
        NEED=$((SRC_SIZE * 2 + 100*1024*1024))
        if [[ "$AVAIL" -gt 0 && "$AVAIL" -lt "$NEED" ]]; then
            echo "Error: Insufficient space in $TMP_PARENT (avail $(numfmt --to=iec "$AVAIL" 2>/dev/null || echo "$AVAIL"), need ~$(numfmt --to=iec "$NEED" 2>/dev/null || echo "$NEED") for ~2x source + 100MiB headroom). Free space or pick a larger pool." >&2
            exit 1
        fi
        POOL_AVAIL=$(df --output=avail -B1 "$POOL_PATH" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)
        if [[ "$POOL_AVAIL" -gt 0 && "$POOL_AVAIL" -lt "$SRC_SIZE" ]]; then
            echo "Error: Insufficient space in pool $POOL_PATH (avail $(numfmt --to=iec "$POOL_AVAIL" 2>/dev/null || echo "$POOL_AVAIL"), need at least source size). Free space or pick another pool." >&2
            exit 1
        fi
        # Hard cap against absurd archives (e.g. >100 GiB compressed already
        # suspicious for an OVA; legitimate Kali etc. are <15 GiB compressed)
        if [[ "$SRC_SIZE" -gt $((100*1024*1024*1024)) ]]; then
            echo "Error: Source archive >100 GiB ($SRC_SIZE bytes) — refusing (possible bomb or unsupported). Use a smaller OVA/VMDK." >&2
            exit 1
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
# Secure temp dir: mktemp gives 0700; do not widen to 0755. 0755 made the
# intermediate QCOW2 (created with default umask 022 → 0644) world-readable
# while the temp dir was traversable, leaking guest data to local users.
# Keep 0700 (or 0750/0710 with group libvirt if qemu must traverse when
# TEMP_DIR is under the pool). We use 0700 and best-effort chgrp.
chmod 700 "$TEMP_DIR" 2>/dev/null || true
chgrp libvirt "$TEMP_DIR" 2>/dev/null || chgrp qemu "$TEMP_DIR" 2>/dev/null || true
# If pool temp needed qemu traversal, allow group x without world x:
if [[ "$TEMP_DIR" == "$POOL_PATH"* ]]; then
    chmod 750 "$TEMP_DIR" 2>/dev/null || chmod 710 "$TEMP_DIR" 2>/dev/null || true
fi

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
    # Enforce decompression size and time limit (gzip bomb). gzip -l gives
    # uncompressed size in field 2; compare to available space and 80 GiB cap.
    if command -v gzip >/dev/null 2>&1; then
        GZ_UNCOMP=$(gzip -l -- "$FILE" 2>/dev/null | awk 'NR==2 {print $2+0}')
        if [[ "${GZ_UNCOMP:-0}" -gt 0 ]]; then
            AVAIL_GZ=$(df --output=avail -B1 "$TEMP_DIR" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)
            HARD_GZ=$((80*1024*1024*1024))
            if [[ "$GZ_UNCOMP" -gt "$HARD_GZ" ]]; then
                echo "Error: VMDK.GZ uncompressed size $GZ_UNCOMP bytes (>80 GiB) — refusing (likely bomb)." >&2
                exit 1
            fi
            if [[ "$AVAIL_GZ" -gt 0 && "$AVAIL_GZ" -lt "$((GZ_UNCOMP + 200*1024*1024))" ]]; then
                echo "Error: Not enough space to decompress VMDK.GZ (need ~$GZ_UNCOMP bytes + 200MiB, avail $AVAIL_GZ in $TEMP_DIR)." >&2
                exit 1
            fi
        fi
    fi
    # Time-bounded decompression (10 min)
    if command -v timeout >/dev/null 2>&1; then
        if ! timeout --preserve-status --kill-after=30 600 bash -c 'gzip -dc -- "$1" > "$2"' _ "$FILE" "$VMDK_FILE" 2>&1 | stdbuf -oL cat; then
            rc=${PIPESTATUS[0]:-$?}
            echo "Error: gzip decompression failed or timed out (exit $rc, likely bomb)." >&2
            exit 1
        fi
    else
        gzip -dc -- "$FILE" > "$VMDK_FILE"
    fi
    echo "Decompressed to $VMDK_FILE" | stdbuf -oL cat
else
    # Assume OVA (tar archive) — enforce expansion-size and time limit.
    # The early check at :80-97 only sees compressed size; a zip-bomb can be
    # tiny on disk but expand to fill the filesystem. Before tar -xf, sum the
    # uncompressed members via tar -tvf and compare to free space in TEMP_DIR,
    # and wrap extraction in timeout so a decompression bomb cannot hang the
    # import indefinitely.
    echo "Extracting OVA $FILE to $TEMP_DIR..." | stdbuf -oL cat
    if ! tar -tf "$FILE" >/dev/null 2>&1; then
        echo "Warning: File does not appear to be a valid tar archive, trying anyway..." >&2 | stdbuf -oL cat
    else
        # Enforce expansion-size: sum member sizes (field 3 of tar -tvf)
        # GNU tar format: "-rw-r--r-- user/group 12345 2024-... name"
        TAR_TOTAL=$(tar -tvf "$FILE" 2>/dev/null | awk '{s+=$3} END {print s+0}')
        TAR_TOTAL=${TAR_TOTAL:-0}
        if [[ "$TAR_TOTAL" -gt 0 ]]; then
            AVAIL_TMP=$(df --output=avail -B1 "$TEMP_DIR" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)
            # Need decompressed + converted qcow2 roughly 2x, keep 200MiB headroom
            NEED_TAR=$((TAR_TOTAL + TAR_TOTAL + 200*1024*1024))
            # Also enforce absolute cap (e.g. 80 GiB uncompressed is already
            # generous: Kali OVA ~15 GiB -> ~40 GiB qcow2; larger likely a bomb)
            HARD_CAP=$((80*1024*1024*1024))
            if [[ "$TAR_TOTAL" -gt "$HARD_CAP" ]]; then
                echo "Error: OVA uncompressed content $TAR_TOTAL bytes (>80 GiB) — refusing (likely bomb or unsupported)." >&2
                exit 1
            fi
            if [[ "$AVAIL_TMP" -gt 0 && "$AVAIL_TMP" -lt "$NEED_TAR" ]]; then
                echo "Error: Not enough space to extract OVA (need ~$(numfmt --to=iec "$NEED_TAR" 2>/dev/null || echo "$NEED_TAR") for $TAR_TOTAL bytes + conversion, avail $(numfmt --to=iec "$AVAIL_TMP" 2>/dev/null || echo "$AVAIL_TMP") in $TEMP_DIR). Free space or use a larger pool." >&2
                exit 1
            fi
            echo "OVA content size: $(numfmt --to=iec "$TAR_TOTAL" 2>/dev/null || echo "$TAR_TOTAL bytes") (avail $(numfmt --to=iec "$AVAIL_TMP" 2>/dev/null || echo "$AVAIL_TMP"))" | stdbuf -oL cat
        fi
    fi
    # Time-bounded extraction: 10 min for typical OVAs; kills zip-bomb loops
    TAR_CMD=(tar -xf "$FILE" -C "$TEMP_DIR")
    if command -v timeout >/dev/null 2>&1; then
        TAR_CMD=(timeout --preserve-status --kill-after=30 600 tar -xf "$FILE" -C "$TEMP_DIR")
    fi
    if ! "${TAR_CMD[@]}" 2>&1 | stdbuf -oL cat; then
        rc=${PIPESTATUS[0]:-$?}
        if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
            echo "Error: OVA extraction timed out after 10 min (likely bomb or very large archive)." >&2
        else
            echo "Error: Failed to extract OVA archive (exit $rc)" >&2
        fi
        exit 1
    fi
    echo "Extraction done, searching for VMDK..." | stdbuf -oL cat
    # Find VMDK (prefer .vmdk.gz, then .vmdk)
    VMDK_FILE=$(find "$TEMP_DIR" -name "*.vmdk.gz" -print -quit 2>/dev/null || true)
    if [[ -n "$VMDK_FILE" && -f "$VMDK_FILE" ]]; then
        echo "Decompressing $VMDK_FILE..." | stdbuf -oL cat
        # Time-bounded (inherits size limit from TAR_TOTAL check above)
        if command -v timeout >/dev/null 2>&1; then
            if ! timeout --preserve-status --kill-after=30 600 gunzip -- "$VMDK_FILE" 2>&1 | stdbuf -oL cat; then
                echo "Error: gunzip of embedded VMDK.GZ failed or timed out." >&2
                exit 1
            fi
        else
            gunzip -- "$VMDK_FILE"
        fi
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
# Time-bounded conversion (large VMDKs can take many minutes; 30 min cap
# prevents a crafted sparse VMDK from hanging the import). Availability
# already checked at :80-97 via pool space.
if command -v timeout >/dev/null 2>&1; then
    if ! stdbuf -oL timeout --preserve-status --kill-after=30 1800 qemu-img convert -p -O qcow2 -- "$VMDK_FILE" "$QCOW2_TEMP_PATH" 2>&1 | stdbuf -oL cat; then
        rc=${PIPESTATUS[0]:-$?}
        if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
            echo "Error: qemu-img convert timed out after 30 min." >&2
        else
            echo "Error: qemu-img convert failed (exit $rc)" >&2
        fi
        exit 1
    fi
elif ! stdbuf -oL qemu-img convert -p -O qcow2 -- "$VMDK_FILE" "$QCOW2_TEMP_PATH" 2>&1 | stdbuf -oL cat; then
    echo "Error: qemu-img convert failed" >&2
    exit 1
fi

if [[ ! -f "$QCOW2_TEMP_PATH" ]]; then
    echo "Error: QCOW2 file not created at $QCOW2_TEMP_PATH" >&2
    exit 1
fi

echo "Conversion successful: $QCOW2_TEMP_PATH ($(du -h "$QCOW2_TEMP_PATH" | cut -f1))" | stdbuf -oL cat
# Restrict temp QCOW2 immediately — qemu-img respects umask (022 → 644)
# so without this the file is world-readable while TEMP_DIR was traversable.
chmod 600 "$QCOW2_TEMP_PATH" 2>/dev/null || true
chgrp libvirt "$QCOW2_TEMP_PATH" 2>/dev/null || chgrp qemu "$QCOW2_TEMP_PATH" 2>/dev/null || true

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
    # Secure disk permissions even on --no-create: 640 (owner rw, group r)
    # not 644. Without this the early exit at 267 skipped the chmod 640 at
    # 291-292, leaving the QCOW2 world-readable when pool is traversable
    # (e.g. ~/VMs 755). See also temp dir fix at 117.
    chmod 640 -- "$FINAL_PATH" 2>/dev/null || chmod 600 -- "$FINAL_PATH" 2>/dev/null || true
    chgrp libvirt -- "$FINAL_PATH" 2>/dev/null || chgrp qemu -- "$FINAL_PATH" 2>/dev/null || true
    # Refresh pool if it's a libvirt pool
    # Fix: previously used awk system(cmd) with POOL_PATH interpolated into a
    # shell command (252-254). A crafted pool <path> like '"; touch /tmp/pwn; "'
    # from pool-dumpxml would execute arbitrary code as the importing user.
    # Removed that vulnerable awk block entirely. Now only the safe bash loop
    # below is used: pool path is compared with bash [[ == ]] without ever
    # invoking a shell, so metacharacters are treated as plain data.
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
# Secure disk permissions: 640 not 644 — 644 made guest FS world-readable
# when pool path was traversable (e.g. ~/VMs 755). Use 640 (owner rw,
# group r for qemu via libvirt/qemu group) and no world perms, with
# best-effort chgrp so qemu can still read without widening.
chmod 640 -- "$FINAL_PATH" 2>/dev/null || chmod 600 -- "$FINAL_PATH" 2>/dev/null || true
chgrp libvirt -- "$FINAL_PATH" 2>/dev/null || chgrp qemu -- "$FINAL_PATH" 2>/dev/null || true
# For home pools, parent dirs need o+x already handled at pool creation
# (omarchy-kvm-pool/pool-set-default use 755/711 on parents). Do not
# chmod parents here and do not re-add world-read to the disk.
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
