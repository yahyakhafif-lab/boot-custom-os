# boot_custom_encrypted_os

Build a **LUKS2-encrypted** custom OS **locally** (like `../boot_custom_os/`, but
encrypted), flash it to a Verda Confidential VM, and unlock it after every
(re)boot by typing the passphrase into an **attested** initramfs. Adds
**data-at-rest** encryption on top of SEV-SNP's data-in-use protection.

Design + threat model: [`../specs/boot_custom_encrypted_os.md`](../specs/boot_custom_encrypted_os.md).
Validated end-to-end with **Ubuntu 25.10 (questing)** on instance
`81a80d55-…` (`86.38.182.72`): LUKS2/aes-xts root, attested unlock, clean boot,
data-at-rest proven (marker absent in raw `/dev/vda4`). Re-validated on the
current default, **Ubuntu 26.04 (resolute)**: same result — all six
attestation steps passed unassisted, LUKS unlocked, `switch_root` completed.

## Files (mirror boot_custom_os + an attest step)

| Script | Where | What |
|---|---|---|
| `00_build_image.sh` | local, **`sudo`** | downloads + customizes the questing 25.10 cloud image (same as boot_custom_os/00), then builds an encrypted raw image: unencrypted `/boot` (kernel + **unlock initramfs** + `lib/systemd` marker) and a **LUKS2** root. Also bakes a first-boot service that **grows the root to fill the disk** (see below). Exports `verify/` (kernel, initrd, cmdline, LUKS UUID). |
| `attested_initramfs.sh` | called by `00` | installs the attestation + unlock initramfs hooks (ephemeral host key, SNP-report endpoint, `cryptroot` unlock, decoy-root swap) into a target rootfs. Kept separate so `00` stays close to `boot_custom_os/00`. |
| `01_setup_initramfs_ssh.sh` | local | installs dropbear + a pause hook on the running VM, then **powers it off (sysrq)**. You **Start it from the Verda console**; it boots into a RAM-only rescue (`/dev/vda` free). |
| `02_flash.sh` | local | streams the encrypted image onto `/dev/vda` (gzip over ssh), then **powers it off**. You **Start it from the Verda console**; Verda extracts our unlock initramfs and boots it. |
| `03_attest_and_unlock.sh` | local | verifies ① AMD signature, ② launch **MEASUREMENT == expected**, ③ `REPORT_DATA == SHA-512(ssh host key)`, then sends the passphrase to `cryptroot-unlock`. |

Config lives in `.env` (copy from `.env_sample`): `REMOTE`, `SSH_KEY`,
`LUKS_PASS`, attestation params, and the fixed cc-template UUIDs.

CC VMs can't reboot from inside, so — like `boot_custom_os/` — `01`/`02` power
the VM off and you **Start it from the Verda console** (each script then waits
for SSH to come back).

## Usage

```bash
cp .env_sample .env      # set REMOTE, SSH_KEY, LUKS_PASS
sudo bash 00_build_image.sh         # -> questing-encrypted-raw.img + verify/
source .env && scp $SSH_OPTS "$REMOTE":/boot/OVMF.amdsev.fd verify/OVMF.amdsev.fd   # for the measurement
./01_setup_initramfs_ssh.sh         # rescue prep + poweroff; then Start in Verda console
./02_flash.sh                       # flash + poweroff;        then Start in Verda console
./03_attest_and_unlock.sh           # attest + unlock
```

`03` auto-installs `snpguest` (curl → `~/.local/bin`) and `sev-snp-measure`
(pipx) if missing — same approach as `measured_boot/measure_kernel.sh`. It pins
`OVMF`/`kernel`/`initrd` to the local `verify/` build artifacts but **derives the
vCPU signature/count and the kernel cmdline from the running guest over SSH**
(reading `/proc/cpuinfo` + `/proc/cmdline` in the attested initramfs), the same
`${VAR:-…}` override pattern as `measured_boot/measure_boot.sh`. This matters: the
measured vCPU signature is the *guest-visible* one (QEMU's virtual `EPYC-Turin` =
family 26 / model 0 / stepping 0), **not** the host silicon (model 2 / stepping 1),
and the cmdline tracks the `root=UUID` Verda re-derives each boot. The expected
measurement is recomputed each run and written to `verify/expected_measurement.txt`.
Override any of `OVMF`/`KERNEL`/`INITRD`/`APPEND`/`VCPUS`/`VCPU_FAMILY`/`VCPU_MODEL`/
`VCPU_STEPPING` via env vars.

## Why it boots (Verda-specific)

Verda's provisioner re-derives `root=UUID=` on every start by mounting partitions
and picking the one with `sbin/init`/`lib/systemd` (`kernel_extract.py`). A LUKS
root can't be mounted → it would fall back to *standard boot and lose the
`kernelHashes` measurement*. So the build puts an empty **`lib/systemd` marker**
on the unencrypted `/boot` partition: the extractor picks it, sets
`root=UUID=<boot-uuid>` (predictable → reproducible measurement), and direct-boots
our initramfs. A `local-bottom` hook then swaps to `/dev/mapper/cryptroot` before
`switch_root`.

## Gotchas baked into the scripts

1. **Marker + ROOT swap** (above) — keeps direct-kernel-boot / measurement.
2. `zzswaproot` unmounts the decoy root **directly** (busybox-initramfs has no
   `mountpoint`) and **kills the attestation httpd** before `switch_root`, else
   `/dev/vda3` stays busy → emergency mode. `/boot`,`/boot/efi` also use `nofail`.
3. `cryptroot-unlock` (`cat >PASSFIFO`) needs the passphrase with **no trailing
   newline** (`printf '%s'`).
4. `ESP_VOLID` is the single source of truth for the ESP's fstab entry —
   `00_build_image.sh` derives `UUID=XXXX-XXXX` from it, so changing it in
   `.env` is safe and doesn't need a matching manual edit elsewhere.

## First-boot grow (fill the disk)

`boot_custom_os` fills the disk with a firstboot `growpart`+`resize2fs`, but on a
LUKS root `cryptsetup resize` needs the volume key — and it always demands the
passphrase (even with the key in the keyring), and re-sending it over the
non-attested post-boot SSH would leak it. So the build adds a **disposable
random keyfile** as a 2nd LUKS keyslot and a oneshot `grow-cryptroot.service`
that, on first boot: `growpart` (no-op — Verda already grows the partition) →
`cryptsetup resize --key-file` → `resize2fs` → `luksRemoveKey` (drops the
disposable slot) → `shred` the keyfile. Net result: root fills the disk
automatically and **no extra unlock secret persists** (only the passphrase
keyslot remains). Verified: 8.7 G → 204 G on a 208 G disk, keyslots back to 1.

## Operating it (every reboot)

CC VMs can't reboot from inside — **Start the VM from the Verda console**, then:

```bash
./03_attest_and_unlock.sh    # attest + send passphrase
```
The VM parks in the attested unlock initramfs (dropbear `:22`, report `:9000`)
until `03` verifies attestation and sends the passphrase; then it boots the
encrypted OS.
