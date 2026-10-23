#!/bin/bash
# Runs LOCALLY. Streams the OS image onto /dev/vda (while the VM is in
# initramfs SSH mode from 01_setup_initramfs_ssh.sh), then waits for the
# new OS to come up after starting the VM from the Verda console.
#
# THIS IS DESTRUCTIVE: /dev/vda is overwritten.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

: "${REMOTE:?Edit .env and set REMOTE}"

IMG=${IMG:-"$SCRIPT_DIR/questing-server-raw.img"}
DISK=${DISK:-/dev/vda}

# ---- check image exists ----
if [ ! -f "$IMG" ]; then
  echo "ERROR: Image not found at $IMG"
  echo "  Run: sudo bash $SCRIPT_DIR/00_build_image.sh"
  exit 1
fi

IMG_SIZE=$(du -h "$IMG" | cut -f1)
echo "==> Image: $IMG ($IMG_SIZE)"

# ---- verify /dev/vda is free ----
echo ""
echo "==> Verifying /dev/vda is not mounted on $REMOTE"
ROOT_MOUNTS=$(ssh $SSH_OPTS "$REMOTE" \
  "grep -c '/dev/vda' /proc/mounts 2>/dev/null || true")
if [ "$ROOT_MOUNTS" -gt 0 ]; then
  echo ""
  echo "ERROR: /dev/vda appears to be mounted — aborting to avoid data loss."
  exit 1
fi
echo "  /dev/vda not mounted — safe to flash."

# ---- stream and flash ----
echo ""
echo "==> Flashing $IMG -> $REMOTE:$DISK"
echo "    Streaming via ssh | dd. Connection drops when the VM powers off."
echo ""

if command -v pv >/dev/null 2>&1; then
  STREAMER="pv --rate --eta --progress"
else
  echo "    (install pv for a progress bar: sudo apt-get install pv)"
  STREAMER="cat"
fi

$STREAMER "$IMG" | gzip -1 | ssh $SSH_OPTS "$REMOTE" \
  "gzip -d | dd of=$DISK bs=4194304 && sync && echo 'flash complete' && sleep 5 && echo o > /proc/sysrq-trigger" \
  || true  # ssh exits non-zero when the remote powers off and drops the connection
# busybox dd does not support bs=4M or conv=fsync — use numeric bytes + separate sync.
# sysrq 'o' powers off the VM; CC VMs cannot reboot from inside — Start from Verda is required.

# ---- wait for new OS ----
cat <<'EOF'

Flash complete. In-guest poweroff issued.

>>> In the Verda console: once the VM is offline, Start it again.
    Note: if the VM is already running, Shutdown it first, then Start it.

Waiting for new OS to come up...
EOF
sleep 10
for i in $(seq 1 120); do
  sleep 5
  if ssh -o ConnectTimeout=4 -o BatchMode=yes \
        $SSH_OPTS "$REMOTE" true 2>/dev/null; then
    echo ""
    echo "==> New OS is up on $REMOTE."
    exit 0
  fi
  echo "  ... waiting for new OS ($((i * 5 + 10))s) — did you Start the VM?"
done

echo ""
echo "ERROR: New OS did not answer SSH within 610 s."
echo "Check that the VM was Started from the Verda console."
exit 1
