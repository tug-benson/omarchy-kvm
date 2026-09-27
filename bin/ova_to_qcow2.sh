#!/usr/bin/env bash
set -euo pipefail

# ova_to_qcow2.sh - Non-interactive OVA/VMDK to qcow2 conversion + KVM VM creation
# Adapted for Omarchy panel (no read -p, CLI args, set -euo pipefail, autodetect, temp dir owned by user)
# Usage: ova_to_qcow2.sh --file <path> --vm-name <name> --memory <MB> --vcpus <n> --pool-path </path> --os-variant <id> [--no-create] [--overwrite]
# --no-create: only convert, do not create VM
# --overwrite: allow replacing an existing destination QCOW2 (default: refuse).
#   Without --overwrite the script never deletes the existing disk. With
#   --overwrite the old disk is moved to a .pre-import backup first and only
#   removed after the new image (and virt-install, if any) succeed; on any
#   failure the backup is restored so a repeated import or colliding VM name
#   cannot silently destroy the prior guest disk.
# Dependencies: tar, gzip, qemu-img, virsh, virt-install, zenity (for UI picker, not for script), df

usage() {
    echo "Usage: $0 --file <path> --vm-name <name> --memory <MB> --vcpus <n> --pool-path </path> --os-variant <id> [--no-create] [--overwrite]" >&2
    echo "  --file        Path to OVA, VMDK or VMDK.GZ file" >&2
    echo "  --vm-name     Name for the new VM (alnum, ., _, -)" >&2
    echo "  --memory      RAM in MB (e.g., 2048)" >&2
    echo "  --vcpus       Number of vCPUs (e.g., 2)" >&2
    echo "  --pool-path   Target pool directory (e.g., /var/lib/libvirt/images or /home/user/VMs)" >&2
    echo "  --os-variant  OS variant id (e.g., generic, debian12, ubuntu24.04) - see osinfo-query" >&2
    echo "  --no-create   Only convert to qcow2, do not create VM" >&2
    echo "  --overwrite   Replace existing destination QCOW2 (default: refuse; old disk is backed up and restored on failure)" >&2
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
OVERWRITE=0

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
        --overwrite) OVERWRITE=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

# Helper: refuse an existing destination by default, or back it up when
# --overwrite was given. Never deletes the old disk outright: with
# --overwrite the existing file (or symlink) is moved aside to
# "$FINAL_PATH.pre-import.<pid>" and BACKUP_PATH is set; the caller must
# remove the backup only after the new image and VM operation succeed,
# and restore it on any failure.
BACKUP_PATH=""
refuse_or_backup_existing() {
    local dest="$1"
    BACKUP_PATH=""
    if [[ -e "$dest" || -L "$dest" ]]; then
        if [[ "$OVERWRITE" -ne 1 ]]; then
            echo "Error: Refusing: destination already exists: $dest" >&2
            echo "A repeated import or colliding VM name would otherwise silently destroy the prior guest disk." >&2
            echo "Pass --overwrite to replace it (old disk is backed up until the new image and VM operation succeed), or choose another --vm-name." >&2
            exit 1
        fi
        BACKUP_PATH="${dest}.pre-import.$$"
        if [[ -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ]]; then
            echo "Error: Backup path already exists, refusing to overwrite: $BACKUP_PATH" >&2
            exit 1
        fi
        if ! mv -- "$dest" "$BACKUP_PATH"; then
            echo "Error: Failed to back up existing disk $dest to $BACKUP_PATH" >&2
            exit 1
        fi
        echo "Existing disk moved to backup: $BACKUP_PATH (will be removed only after the new image succeeds)..." | stdbuf -oL cat
    fi
}
restore_backup() {
    local dest="$1"
    if [[ -n "$BACKUP_PATH" && ( -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ) ]]; then
        rm -f -- "$dest" 2>/dev/null || true
        if mv -- "$BACKUP_PATH" "$dest"; then
            echo "Restored previous disk from backup: $BACKUP_PATH -> $dest" >&2 | stdbuf -oL cat
        else
            echo "Error: Failed to restore backup $BACKUP_PATH (previous disk preserved there, new image at $dest may be incomplete)" >&2
        fi
        BACKUP_PATH=""
    fi
}
drop_backup() {
    if [[ -n "$BACKUP_PATH" && ( -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ) ]]; then
        rm -f -- "$BACKUP_PATH"
        echo "Backup removed after success: $BACKUP_PATH" | stdbuf -oL cat
    fi
    BACKUP_PATH=""
}

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

# run_with_write_cap <cap_bytes> <timeout_secs> -- <command...>
# Runs <command> with a kernel-enforced per-file size cap (ulimit -f, i.e.
# RLIMIT_FSIZE → SIGXFSZ, synchronous, no poll race) plus a polling watchdog
# on TEMP_DIR aggregate growth for the multi-file case. A timeout alone does
# not cap bytes written, and polling alone can miss a sub-second burst, so a
# crafted archive whose listing and extraction diverge could otherwise fill
# the filesystem. Kill on cap overrun (returns 137) or timeout (returns 124,
# mirroring timeout(1)); otherwise returns the command's exit code.
run_with_write_cap() {
    local cap_bytes="$1"; shift
    local timeout_secs="$1"; shift
    if [[ "${1:-}" == "--" ]]; then shift; fi
    if [[ "${cap_bytes:-0}" -le 0 ]]; then
        echo "Error: refusing to run an unbounded write step (cap=$cap_bytes)." >&2
        return 1
    fi
    local step_log="$TEMP_DIR/.bounded-step.log"
    : > "$step_log" 2>/dev/null || true
    local base used rc=0 start=$SECONDS
    # NOTE: '|| true' — under 'set -o pipefail' a failing du would otherwise
    # abort via 'set -e' instead of falling back to 0.
    base=$(du -sb "$TEMP_DIR" 2>/dev/null | cut -f1 || true); base=${base:-0}
    # Kernel per-file cap, exact bytes via prlimit (RLIMIT_FSIZE → SIGXFSZ,
    # synchronous, no poll race). Applies per file written by the child (the
    # step log itself is tiny); aggregate across files is covered by the
    # polling watchdog below. (ulimit -f is NOT used: its block factor is
    # shell-dependent — observed 1024 here vs documented 512 — so it cannot
    # express an exact byte cap; prlimit from util-linux can.)
    if command -v prlimit >/dev/null 2>&1; then
        ( prlimit --fsize="$cap_bytes" -- "$@" ) >"$step_log" 2>&1 &
    else
        echo "Warning: prlimit missing — per-file byte cap unavailable, aggregate watchdog only." >&2
        "$@" >"$step_log" 2>&1 &
    fi
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( SECONDS - start >= timeout_secs )); then
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            cat "$step_log" 2>/dev/null || true
            echo "Error: operation timed out after ${timeout_secs}s (likely bomb or very large archive)." >&2
            return 124
        fi
        used=$(du -sb "$TEMP_DIR" 2>/dev/null | cut -f1 || true); used=${used:-0}
        if (( used - base > cap_bytes )); then
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            cat "$step_log" 2>/dev/null || true
            echo "Error: operation exceeded enforced write cap of $cap_bytes bytes in $TEMP_DIR — refusing (likely bomb)." >&2
            return 137
        fi
        sleep 0.5
    done
    wait "$pid" || rc=$?
    cat "$step_log" 2>/dev/null || true
    if (( rc == 153 )); then
        # 128+SIGXFSZ(25): child hit the kernel per-file write cap above.
        echo "Error: operation exceeded enforced per-file write cap of $cap_bytes bytes — refusing (likely bomb)." >&2
        return 137
    fi
    return $rc
}

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
        # Bound the part set first: enumerate explicitly (no blind glob into
        # cp), sum exact sizes via stat, and enforce free space + a live
        # write cap. An uncapped 'cp *.vmdk' of a large or attacker-supplied
        # split set could otherwise exhaust this filesystem before
        # conversion, with no check at all. Sizes here are exact (stat, not
        # estimates), so no absolute hard cap is needed — but refuse when a
        # part cannot be sized (fail closed).
        shopt -s nullglob
        SPLIT_PARTS=( "$VMDK_DIR"/"$VMDK_BASE"*.vmdk )
        shopt -u nullglob
        SPLIT_TOTAL=0
        for p in "${SPLIT_PARTS[@]}"; do
            if [[ ! -f "$p" || -L "$p" ]]; then
                echo "Error: Split part is not a regular file: $p (refusing unbounded copy)" >&2
                exit 1
            fi
            # NOTE: '|| true' — under 'set -o pipefail' a failing stat would
            # otherwise abort via 'set -e' before the fail-closed check runs.
            PSZ=$(stat -c%s -- "$p" 2>/dev/null || stat -f%z -- "$p" 2>/dev/null || echo 0 || true)
            PSZ=${PSZ:-0}
            if [[ "$PSZ" -le 0 ]]; then
                echo "Error: Cannot size split part $p — refusing to copy an unbounded set." >&2
                exit 1
            fi
            SPLIT_TOTAL=$((SPLIT_TOTAL + PSZ))
        done
        if [[ "${#SPLIT_PARTS[@]}" -eq 0 || "$SPLIT_TOTAL" -le 0 ]]; then
            echo "Error: Split VMDK set is empty or unsizable — refusing." >&2
            exit 1
        fi
        # stat reports apparent size, so sparse parts are over-counted: safe
        # direction (may refuse, never overflows). Need parts + converted
        # qcow2 (~parts again) + 200MiB headroom.
        AVAIL_SPLIT=$(df --output=avail -B1 "$TEMP_DIR" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)
        NEED_SPLIT=$((SPLIT_TOTAL + SPLIT_TOTAL + 200*1024*1024))
        if [[ "$AVAIL_SPLIT" -gt 0 && "$AVAIL_SPLIT" -lt "$NEED_SPLIT" ]]; then
            echo "Error: Not enough space for split VMDK set (need ~$(numfmt --to=iec "$NEED_SPLIT" 2>/dev/null || echo "$NEED_SPLIT") for ${#SPLIT_PARTS[@]} parts + conversion, avail $(numfmt --to=iec "$AVAIL_SPLIT" 2>/dev/null || echo "$AVAIL_SPLIT") in $TEMP_DIR). Free space or use a larger pool." >&2
            exit 1
        fi
        echo "Split set: ${#SPLIT_PARTS[@]} parts, $(numfmt --to=iec "$SPLIT_TOTAL" 2>/dev/null || echo "$SPLIT_TOTAL bytes") (avail $(numfmt --to=iec "$AVAIL_SPLIT" 2>/dev/null || echo "$AVAIL_SPLIT"))" | stdbuf -oL cat
        # Write-capped + time-bounded copy (10 min). --sparse=always keeps
        # sparse parts small; the cap still bounds apparent bytes.
        rc=0
        run_with_write_cap "$((SPLIT_TOTAL + 200*1024*1024))" 600 -- cp --sparse=always -- "${SPLIT_PARTS[@]}" "$TEMP_DIR"/ || rc=$?
        if (( rc != 0 )); then
            if [[ "$rc" -eq 124 ]]; then
                echo "Error: Split VMDK copy timed out after 10 min." >&2
            elif [[ "$rc" -eq 137 ]]; then
                echo "Error: Split VMDK copy exceeded write cap (likely bomb)." >&2
            else
                echo "Error: Split VMDK copy failed (exit $rc) — old pool disk untouched." >&2
            fi
            exit 1
        fi
        VMDK_FILE="$TEMP_DIR/$(basename "$FILE")"
        if [[ ! -f "$VMDK_FILE" ]]; then
            echo "Error: Expected part $(basename "$FILE") missing after copy — refusing." >&2
            exit 1
        fi
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
            # Same bounding as the split set: exact stat size, free-space
            # check and live write cap instead of an uncapped cp.
            COPY_SIZE=$(stat -c%s -- "$FILE" 2>/dev/null || stat -f%z -- "$FILE" 2>/dev/null || echo 0 || true)
            COPY_SIZE=${COPY_SIZE:-0}
            if [[ "$COPY_SIZE" -le 0 ]]; then
                echo "Error: Cannot size $FILE — refusing to copy an unbounded file." >&2
                exit 1
            fi
            AVAIL_CP=$(df --output=avail -B1 "$TEMP_DIR" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)
            NEED_CP=$((COPY_SIZE + COPY_SIZE + 200*1024*1024))
            if [[ "$AVAIL_CP" -gt 0 && "$AVAIL_CP" -lt "$NEED_CP" ]]; then
                echo "Error: Not enough space to copy VMDK (need ~$(numfmt --to=iec "$NEED_CP" 2>/dev/null || echo "$NEED_CP"), avail $(numfmt --to=iec "$AVAIL_CP" 2>/dev/null || echo "$AVAIL_CP") in $TEMP_DIR)." >&2
                exit 1
            fi
            rc=0
            run_with_write_cap "$((COPY_SIZE + 200*1024*1024))" 600 -- cp --sparse=always -- "$FILE" "$VMDK_FILE" || rc=$?
            if (( rc != 0 )); then
                if [[ "$rc" -eq 124 ]]; then
                    echo "Error: VMDK copy timed out after 10 min." >&2
                elif [[ "$rc" -eq 137 ]]; then
                    echo "Error: VMDK copy exceeded write cap (likely bomb)." >&2
                else
                    echo "Error: VMDK copy failed (exit $rc)." >&2
                fi
                exit 1
            fi
            echo "Copied single VMDK to $VMDK_FILE" | stdbuf -oL cat
        fi
    fi
elif [[ $IS_VMDK_GZ -eq 1 ]]; then
    echo "Input is VMDK.GZ, decompressing..." | stdbuf -oL cat
    VMDK_FILE="$TEMP_DIR/$(basename "${FILE%.gz}")"
    # Enforce decompression size and write cap (gzip bomb). gzip -l gives
    # uncompressed size in field 2; compare to available space and 80 GiB cap.
    # Fail closed when the size is unknown: without a bound we cannot cap
    # bytes written, so refuse instead of decompressing blindly.
    # NOTE: '|| true' — under 'set -o pipefail' a failing gzip -l would
    # otherwise abort via 'set -e' before the fail-closed check below runs.
    GZ_UNCOMP=$(gzip -l -- "$FILE" 2>/dev/null | awk 'NR==2 {print $2+0}' || true)
    GZ_UNCOMP=${GZ_UNCOMP:-0}
    if [[ "$GZ_UNCOMP" -le 0 ]]; then
        echo "Error: Cannot determine VMDK.GZ uncompressed size (gzip -l failed) — refusing to decompress an unbounded archive." >&2
        exit 1
    fi
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
    # Write-capped + time-bounded decompression (10 min). NOTE: capture rc
    # via '|| rc=$?' — 'if ! cmd; then rc=$?' would read the negated
    # status (0), not the command's code.
    rc=0
    run_with_write_cap "$((GZ_UNCOMP + 200*1024*1024))" 600 -- bash -c 'gzip -dc -- "$1" > "$2"' _ "$FILE" "$VMDK_FILE" || rc=$?
    if (( rc != 0 )); then
        if [[ "$rc" -eq 124 ]]; then
            echo "Error: gzip decompression timed out after 10 min (likely bomb)." >&2
        elif [[ "$rc" -eq 137 ]]; then
            echo "Error: gzip decompression exceeded write cap (likely bomb; header size diverged from actual output)." >&2
        else
            echo "Error: gzip decompression failed (exit $rc)." >&2
        fi
        exit 1
    fi
    echo "Decompressed to $VMDK_FILE" | stdbuf -oL cat
else
    # Assume OVA (tar archive) — enforce expansion-size, write cap and time
    # limit. The early check only sees compressed size; a zip-bomb can be
    # tiny on disk but expand to fill the filesystem. Before tar -xf, sum the
    # uncompressed members via tar -tvf and compare to free space in TEMP_DIR.
    # Fail closed when the listing fails or yields no boundable size: an
    # archive that errors after an oversized member must never reach tar -xf,
    # and the extraction itself runs under a live write cap (a timeout alone
    # does not cap bytes written).
    echo "Extracting OVA $FILE to $TEMP_DIR..." | stdbuf -oL cat
    if ! tar -tf "$FILE" >/dev/null 2>&1; then
        echo "Error: File is not a valid tar archive (tar -tf failed) — refusing to extract an unbounded archive." >&2
        exit 1
    fi
    # Enforce expansion-size: sum member sizes (field 3 of tar -tvf)
    # GNU tar format: "-rw-r--r-- user/group 12345 2024-... name"
    # NOTE: '|| true' — under 'set -o pipefail' a failing tar -tvf would
    # otherwise abort via 'set -e' before the fail-closed check below runs.
    TAR_TOTAL=$(tar -tvf "$FILE" 2>/dev/null | awk '{s+=$3} END {print s+0}' || true)
    TAR_TOTAL=${TAR_TOTAL:-0}
    if [[ "$TAR_TOTAL" -le 0 ]]; then
        echo "Error: Cannot bound OVA uncompressed size (empty or unreadable member list) — refusing to extract an unbounded archive." >&2
        exit 1
    fi
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
    # Write-capped + time-bounded extraction (10 min): kills the runaway even
    # when listing and extraction diverge. NOTE: capture rc via '|| rc=$?'
    # ('if ! cmd; then rc=$?' would read the negated status, 0).
    rc=0
    run_with_write_cap "$NEED_TAR" 600 -- tar -xf "$FILE" -C "$TEMP_DIR" || rc=$?
    if (( rc != 0 )); then
        if [[ "$rc" -eq 124 ]]; then
            echo "Error: OVA extraction timed out after 10 min (likely bomb or very large archive)." >&2
        elif [[ "$rc" -eq 137 ]]; then
            echo "Error: OVA extraction exceeded write cap of $NEED_TAR bytes (listing diverged from actual output; likely bomb)." >&2
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
        # Write-capped + time-bounded (bound inherited from TAR_TOTAL above;
        # cap fits the space verified before extraction). NOTE: rc via
        # '|| rc=$?' ('if ! cmd' would read the negated status, 0).
        rc=0
        run_with_write_cap "$((TAR_TOTAL + 200*1024*1024))" 600 -- gunzip -- "$VMDK_FILE" || rc=$?
        if (( rc != 0 )); then
            if [[ "$rc" -eq 124 ]]; then
                echo "Error: gunzip of embedded VMDK.GZ timed out after 10 min." >&2
            elif [[ "$rc" -eq 137 ]]; then
                echo "Error: gunzip of embedded VMDK.GZ exceeded write cap (likely bomb)." >&2
            else
                echo "Error: gunzip of embedded VMDK.GZ failed (exit $rc)." >&2
            fi
            exit 1
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
    # Refuse an existing destination by default; with --overwrite the old
    # disk is moved to a .pre-import backup and only dropped after success.
    refuse_or_backup_existing "$FINAL_PATH"
    if ! mv -- "$QCOW2_TEMP_PATH" "$FINAL_PATH"; then
        echo "Error: Failed to move QCOW2 to $FINAL_PATH (check permissions)" >&2
        restore_backup "$FINAL_PATH"
        exit 1
    fi
    # Secure disk permissions even on --no-create: 640 (owner rw, group r)
    # not 644, otherwise the convert-only branch would leave the QCOW2
    # world-readable when the pool is traversable (e.g. ~/VMs 755).
    # See also the temp-dir hardening above.
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
    # New image is in place and valid — only now drop the backup (if any).
    drop_backup
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
# Refuse an existing destination by default; with --overwrite the old disk
# is moved to a .pre-import backup and only dropped after virt-install
# succeeds, so a colliding VM name cannot destroy the prior guest disk
# before we know the new VM operation works.
refuse_or_backup_existing "$FINAL_PATH"
if ! mv -- "$QCOW2_TEMP_PATH" "$FINAL_PATH"; then
    echo "Error: Failed to move QCOW2 to $FINAL_PATH" >&2
    restore_backup "$FINAL_PATH"
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
    # Do not leave a half-imported disk in place of the previous one: remove
    # the new image and restore the backup so the prior guest disk survives
    # a failed VM creation.
    if [[ -n "$BACKUP_PATH" && ( -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ) ]]; then
        rm -f -- "$FINAL_PATH" 2>/dev/null || true
        restore_backup "$FINAL_PATH"
    else
        echo "Disk is available at: $FINAL_PATH" >&2
    fi
    exit 1
fi
# VM creation succeeded — only now drop the backup (if any).
drop_backup

echo "----------------------------------------------------------------" | stdbuf -oL cat
echo "VM '$VM_NAME' created successfully." | stdbuf -oL cat
echo "Disk: $FINAL_PATH" | stdbuf -oL cat
echo "Pool: $POOL_PATH" | stdbuf -oL cat
echo "Manage with 'virsh --connect qemu:///system list --all' or virt-manager" | stdbuf -oL cat
echo "----------------------------------------------------------------" | stdbuf -oL cat
