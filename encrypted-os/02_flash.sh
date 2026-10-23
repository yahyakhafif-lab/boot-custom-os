#!/bin/bash
# Runs LOCALLY while the VM is in rescue initramfs (from 01). Streams the
# encrypted raw image onto /dev/vda, then powers the VM off in-guest. CC VMs
# cannot reboot from inside, so you Start it from the Verda console; Verda then
# extracts our unlock initramfs and boots it. Same flow as boot_custom_os/02_flash.sh.
# THIS IS DESTRUCTIVE: /dev/vda is overwritten.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"
: "${REMOTE:?Edit .env and set REMOTE}"
IMG=${IMG:-"$SCRIPT_DIR/encrypted-raw.img"}
DISK=${DISK:-/dev/vda}

[ -f "$IMG" ] || { echo "ERROR: image not found at $IMG — run 00_build_image.sh" >&2; exit 1; }

echo "==> Verifying /dev/vda is not mounted on $REMOTE (rescue mode)"
pid1=$(ssh $SSH_OPTS "$REMOTE" 'cat /proc/1/comm' 2>/dev/null || echo unknown)
[ "$pid1" != systemd ] || { echo "ERROR: PID1=systemd (not in rescue) — run ./01_setup_initramfs_ssh.sh" >&2; exit 1; }
[ "$(ssh $SSH_OPTS "$REMOTE" 'grep -c /dev/vda /proc/mounts || true')" = 0 ] || { echo "ERROR: /dev/vda is mounted — aborting" >&2; exit 1; }
echo "  PID1=$pid1, /dev/vda free."

echo "==> Flashing $IMG ($(du -h "$IMG"|cut -f1)) -> $REMOTE:$DISK"
STREAMER="cat"; command -v pv >/dev/null && STREAMER="pv"
$STREAMER "$IMG" | gzip -1 | ssh $SSH_OPTS "$REMOTE" \
  "gzip -d | dd of=$DISK bs=4194304 && sync && echo 'flash complete' && sleep 5 && echo o > /proc/sysrq-trigger" \
  || true   # ssh exits non-zero when the VM powers off and drops the connection

cat <<'EOF'

Flash complete. In-guest poweroff issued.

>>> In the Verda console: once the VM is offline, Start it again.
    Note: if the VM is already running, Shutdown it first, then Start it.

Waiting for the unlock initramfs (attestation endpoint coming up)...
EOF

sleep 10
for i in $(seq 1 120); do
  sleep 5
  if ssh -o ConnectTimeout=4 -o BatchMode=yes $SSH_OPTS "$REMOTE" "test -f /run/attest/report.bin" 2>/dev/null; then
    echo ""
    echo "==> Unlock initramfs is up on $REMOTE."
    echo "Next step:  ./03_attest_and_unlock.sh"
    exit 0
  fi
  echo "  ... still waiting ($((i * 5 + 10))s) — did you Start the VM from Verda?"
done

echo "ERROR: unlock initramfs did not come up within 610 s." >&2
exit 1
