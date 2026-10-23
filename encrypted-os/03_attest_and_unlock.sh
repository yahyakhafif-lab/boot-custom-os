#!/bin/bash
# Runs LOCALLY after the VM boots into the attested unlock initramfs.
# Verifies BEFORE sending the passphrase: ① AMD signature, ② launch MEASUREMENT
# == expected (OVMF+kernel+initrd+cmdline), ③ REPORT_DATA == SHA-512(ssh host key).
#
# Measurement inputs are obtained at runtime the same way as
# measured_boot/measure_boot.sh (the ${VAR:-<derive>} override pattern):
#   - OVMF/KERNEL/INITRD  : the verifier-pinned build artifacts under verify/.
#   - VCPUS / VCPU_FAMILY / VCPU_MODEL / VCPU_STEPPING : read from the running
#     guest's /proc/cpuinfo over SSH into the attested initramfs. This yields the
#     GUEST-visible CPU signature (QEMU's virtual EPYC-Turin = family 26 / model 0
#     / stepping 0, i.e. VMSA rdx=0x00B00F00) — NOT the host silicon (2/1).
#   - APPEND (kernel cmdline) : read from the guest's /proc/cmdline, so it tracks
#     the root=UUID Verda re-derives on each boot.
# Export any of OVMF/KERNEL/INITRD/APPEND/VCPUS/VCPU_FAMILY/VCPU_MODEL/VCPU_STEPPING
# to override the auto-derivation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$SCRIPT_DIR"
source ./.env
VM_IP=${VM_IP:-${REMOTE#root@}}
VDIR=${VERIFY_DIR:-verify}
PROC_MODEL=${PROC_MODEL:-turin}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# pipx + ~/.local/bin shims may not be on PATH.
export PATH="$PATH:$HOME/.local/bin"; mkdir -p "$HOME/.local/bin"

# Verifier-pinned measurement artifacts (built locally by 00_build_image.sh).
OVMF="${OVMF:-$VDIR/OVMF.amdsev.fd}"
KERNEL="${KERNEL:-$VDIR/vmlinuz}"
INITRD="${INITRD:-$VDIR/initrd.img}"
[ -f "$OVMF" ]   || { echo "Need OVMF at $OVMF (scp it from \$REMOTE:/boot/OVMF.amdsev.fd)"; exit 1; }
[ -f "$KERNEL" ] || { echo "Missing kernel at $KERNEL (run 00_build_image.sh)"; exit 1; }
[ -f "$INITRD" ] || { echo "Missing initrd at $INITRD (run 00_build_image.sh)"; exit 1; }

# Install snpguest if missing (same approach as measured_boot/measure_kernel.sh).
command -v snpguest >/dev/null 2>&1 || {
  echo "[+] Installing snpguest..."
  curl -fsSL https://github.com/virtee/snpguest/releases/download/v0.10.0/snpguest -o "$HOME/.local/bin/snpguest"
  chmod +x "$HOME/.local/bin/snpguest"
}
# Install sev-snp-measure (in an isolated venv via pipx) if missing.
if ! command -v sev-snp-measure >/dev/null 2>&1; then
  echo "[+] Installing sev-snp-measure via pipx..."
  command -v pipx >/dev/null 2>&1 || { sudo apt-get update; sudo apt-get install -y --no-install-recommends pipx; }
  pipx install --quiet sev-snp-measure
fi

echo "==> 1. fetch report + host key"
curl -fsS "http://$VM_IP:$ATTEST_PORT/report.bin"  -o "$WORK/report.bin" || {
  echo "FAIL: could not fetch report.bin from $VM_IP:$ATTEST_PORT"
  echo "      the unlock initramfs may not have produced an SNP report — check"
  echo "      /run/attest/snpguest.log and 'dmesg | grep -i sev' on the guest"
  exit 1
}
[ -s "$WORK/report.bin" ] || { echo "FAIL: report.bin is empty — snpguest report generation failed in the initramfs (check /run/attest/snpguest.log)"; exit 1; }
SERVED=$(curl -fsS "http://$VM_IP:$ATTEST_PORT/hostkey.pub")
KEYSCAN=$(ssh-keyscan -t ed25519 "$VM_IP" 2>/dev/null | grep -m1 ' ssh-ed25519 ' | cut -d' ' -f2-)
echo "    host key: $SERVED"
[ "$SERVED" = "$KEYSCAN" ] || { echo "FAIL: served key != SSH-presented key"; exit 1; }

# Pin the SSH host key we just cross-checked and reuse it both for the runtime
# reads below and for the final cryptroot-unlock (its binding to the report is
# verified in step 6 before any secret is sent).
echo "$VM_IP $SERVED" > "$WORK/known_hosts"
gssh() { ssh -o UserKnownHostsFile="$WORK/known_hosts" -o StrictHostKeyChecking=yes \
             -o HostKeyAlgorithms=ssh-ed25519 -o ConnectTimeout=10 -o BatchMode=yes \
             root@"$VM_IP" "$@"; }

echo "==> 2. derive measurement inputs from the running guest (like measure_boot.sh)"
GUEST=$(gssh 'cat /proc/cpuinfo; echo "@@@CMDLINE@@@"; cat /proc/cmdline')
CPUINFO=${GUEST%%@@@CMDLINE@@@*}
GUEST_CMDLINE=${GUEST##*@@@CMDLINE@@@}
# vCPU count + signature, GUEST-visible (see header). .env/env vars override.
VCPUS="${VCPUS:-$(printf '%s\n' "$CPUINFO" | grep -c '^processor')}"
VCPU_FAMILY="${VCPU_FAMILY:-$(printf '%s\n' "$CPUINFO" | awk '/^cpu family/{print $4; exit}')}"
VCPU_MODEL="${VCPU_MODEL:-$(printf '%s\n' "$CPUINFO" | awk '/^model[^ ]/{print $3; exit}')}"
VCPU_STEPPING="${VCPU_STEPPING:-$(printf '%s\n' "$CPUINFO" | awk '/^stepping/{print $3; exit}')}"
# Reconstruct QEMU's -append by stripping the "initrd=initrd" token it prepends for
# -initrd (sev-snp-measure re-adds it). Fall back to verify/cmdline.txt / $CMDLINE.
APPEND="${APPEND:-$(printf '%s' "$GUEST_CMDLINE" | sed -e 's/^initrd=initrd //' -e 's/ initrd=initrd / /' | tr -d '\n')}"
[ -n "$APPEND" ] || APPEND="${CMDLINE:-$(tr -d '\n' < "$VDIR/cmdline.txt")}"
[ -n "$VCPU_FAMILY" ] && [ -n "$VCPU_MODEL" ] && [ -n "$VCPU_STEPPING" ] && [ "${VCPUS:-0}" -gt 0 ] \
  || { echo "FAIL: could not derive vCPU signature/count from guest /proc/cpuinfo"; exit 1; }
echo "    vCPUs   : $VCPUS (family=$VCPU_FAMILY model=$VCPU_MODEL stepping=$VCPU_STEPPING)"
echo "    cmdline : $APPEND"

echo "==> 3. compute expected measurement (OVMF+kernel+initrd+cmdline+vCPU)"
EXPECTED=$(sev-snp-measure --mode snp --vcpus "$VCPUS" --vcpu-family "$VCPU_FAMILY" \
  --vcpu-model "$VCPU_MODEL" --vcpu-stepping "$VCPU_STEPPING" --ovmf "$OVMF" \
  --kernel "$KERNEL" --initrd "$INITRD" --append "$APPEND" --output-format hex \
  | tr -d ' \n' | tr 'a-f' 'A-F')
printf '%s\n' "$EXPECTED" > "$VDIR/expected_measurement.txt"

echo "==> 4. verify AMD signature (ARK->ASK->VCEK)"
snpguest fetch ca pem "$WORK" "$PROC_MODEL" >/dev/null 2>&1 || snpguest fetch ca pem "$PROC_MODEL" "$WORK" >/dev/null
snpguest fetch vcek pem "$WORK" "$WORK/report.bin" >/dev/null
snpguest verify certs "$WORK" >/dev/null
snpguest verify attestation "$WORK" "$WORK/report.bin" | grep -q "VEK signed" && echo "    AMD signature OK"

echo "==> 5. measurement == expected"
REPORT_MEAS=$(snpguest display report "$WORK/report.bin" | awk '/^Measurement:/{f=1;next}/^[A-Z][a-z]/{f=0}f' | tr -d ' \n' | tr 'a-f' 'A-F')
echo "    report  : $REPORT_MEAS"
echo "    expected: $EXPECTED"
[ "$REPORT_MEAS" = "$EXPECTED" ] || { echo "FAIL: MEASUREMENT MISMATCH — refusing"; exit 1; }

echo "==> 6. report_data == SHA-512(host key)"
REPORT_DATA=$(snpguest display report "$WORK/report.bin" | awk '/^Report Data:/{f=1;next}/^[A-Z][a-z]/{f=0}f' | tr -d ' \n' | tr 'A-F' 'a-f')
CALC=$(printf '%s' "$SERVED" | sha512sum | cut -d' ' -f1)
[ "$REPORT_DATA" = "$CALC" ] || { echo "FAIL: host key NOT bound — possible MITM, refusing"; exit 1; }

echo "==> ATTESTATION OK — sending LUKS passphrase via cryptroot-unlock"
: "${LUKS_PASS:?}"
# cryptroot-unlock does `cat >PASSFIFO`: send WITHOUT a trailing newline.
printf '%s' "$LUKS_PASS" | gssh "cryptroot-unlock" || true
echo "==> passphrase sent — VM should switch_root into the encrypted OS."
