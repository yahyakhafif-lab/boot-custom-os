#!/bin/bash
# Builds a LUKS2-encrypted Ubuntu 26.04 raw image. This tool is
# Debian/Ubuntu-specific (apt packages, initramfs-tools hooks in
# attested_initramfs.sh) — it does not generalize to other distro families
# (e.g. Fedora/RHEL use dracut, not initramfs-tools) without a separate port.
# Same idea as
# boot_custom_os/00_build_image.sh (download + virt-customize the cloud image),
# but then encrypts the root and bakes an attestation + unlock initramfs
# (see attested_initramfs.sh).  Outputs an encrypted raw image ready for dd.
#
# Requires: source .env (SSH_KEY, LUKS_PASS). Run as root (loop/cryptsetup/chroot).
# Requires: libguestfs-tools, qemu-utils, cryptsetup, gdisk, rsync
set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: run as root (sudo $0)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"
: "${SSH_KEY:?Error: SSH_KEY is not set in .env}"
: "${LUKS_PASS:?Error: LUKS_PASS is not set in .env}"

for cmd in virt-customize qemu-img cryptsetup sgdisk rsync mkfs.ext4 mkfs.vfat; do
  command -v "$cmd" &>/dev/null || { echo "Error: $cmd not found" >&2; exit 1; }
done

# Ubuntu 26.04 (resolute) cloud image + output names.
CODENAME=resolute
IMAGENAME="${CODENAME}-server-cloudimg-amd64.img"
RAWNAME=server-raw.img
ENCNAME=encrypted-raw.img
SNPGUEST="$SCRIPT_DIR/snpguest"

# cleanup loop/crypt mounts on exit
SLOOP=""; TLOOP=""
cleanup(){ set +e; umount -R /mnt/enc 2>/dev/null; umount /mnt/src 2>/dev/null
  cryptsetup close cryptroot 2>/dev/null
  [ -n "$TLOOP" ] && losetup -d "$TLOOP" 2>/dev/null; [ -n "$SLOOP" ] && losetup -d "$SLOOP" 2>/dev/null; }
trap cleanup EXIT
modprobe dm-crypt 2>/dev/null || true
[ -x "$SNPGUEST" ] || { curl -fsSL https://github.com/virtee/snpguest/releases/download/v0.10.0/snpguest -o "$SNPGUEST"; chmod +x "$SNPGUEST"; }

# Download + customize the cloud image (ssh key, network, no cloud-init) — same as boot_custom_os
[ -f "$IMAGENAME" ] || wget -O "$IMAGENAME" "https://cloud-images.ubuntu.com/${CODENAME}/current/$IMAGENAME"
cp -f "$IMAGENAME" base.qcow2
virt-customize -a base.qcow2 \
  --root-password disabled \
  --ssh-inject root:string:"$SSH_KEY" \
  --run-command 'sed -i "s/#\?PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config' \
  --mkdir /etc/netplan \
  --write /etc/netplan/01-netcfg.yaml:'network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      critical: true' \
  --run-command 'systemctl disable cloud-init cloud-init-local cloud-config cloud-final 2>/dev/null || true' \
  --truncate /etc/machine-id
qemu-img convert -f qcow2 -O raw base.qcow2 "$RAWNAME"

# Locate the cloud image's root / boot / esp partitions in $RAWNAME image
SLOOP=$(losetup --find --show -P "$RAWNAME"); udevadm settle 2>/dev/null || sleep 1
SRC_ROOT=""; SRC_BOOT=""; SRC_ESP=""; mkdir -p /mnt/src
for p in ${SLOOP}p*; do
  t=$(blkid -o value -s TYPE "$p" 2>/dev/null || true)
  [ "$t" = vfat ] && SRC_ESP="$p"
  if [ "$t" = ext4 ]; then
    mount -o ro "$p" /mnt/src || continue
    { [ -e /mnt/src/sbin/init ] || [ -e /mnt/src/lib/systemd ]; } && SRC_ROOT="$p"
    ls /mnt/src/vmlinuz* &>/dev/null && SRC_BOOT="$p"
    umount /mnt/src
  fi
done
: "${SRC_ROOT:?could not find source root}"; : "${SRC_BOOT:?could not find source /boot}"

# Create the encrypted target: bios / esp / boot (unencrypted) / LUKS2 root
rm -f "$ENCNAME"; truncate -s "${SIZE:-10G}" "$ENCNAME"
sgdisk --clear \
  --new=1:0:+4M    --typecode=1:ef02 --change-name=1:bios \
  --new=2:0:+128M  --typecode=2:ef00 --change-name=2:esp \
  --new=3:0:+1024M --typecode=3:8300 --change-name=3:boot \
  --new=4:0:0      --typecode=4:8300 --change-name=4:luksroot "$ENCNAME"
TLOOP=$(losetup --find --show -P "$ENCNAME"); udevadm settle 2>/dev/null || sleep 1
mkfs.vfat -i "$ESP_VOLID" -n ESP "${TLOOP}p2" >/dev/null
mkfs.ext4 -q -F -U "$BOOT_FS_UUID" -L boot "${TLOOP}p3"
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --pbkdf argon2id "${TLOOP}p4" -
LUKS_UUID=$(cryptsetup luksUUID "${TLOOP}p4")
printf '%s' "$LUKS_PASS" | cryptsetup open "${TLOOP}p4" cryptroot -
mkfs.ext4 -q -F -U "$ROOT_FS_UUID" -L root /dev/mapper/cryptroot
# Add a disposable random keyfile as a 2nd LUKS keyslot so the first-boot resize
# can grow LUKS without the passphrase; the keyslot + keyfile are removed on first boot.
GROWKEY=$(mktemp); head -c 64 /dev/urandom > "$GROWKEY"
printf '%s' "$LUKS_PASS" | cryptsetup luksAddKey "${TLOOP}p4" "$GROWKEY"

# Copy rootfs (-> LUKS), boot and esp; add the extractor marker + kernel symlinks
mkdir -p /mnt/enc; mount /dev/mapper/cryptroot /mnt/enc
mount -o ro "$SRC_ROOT" /mnt/src; rsync -aHAX /mnt/src/ /mnt/enc/; umount /mnt/src
mkdir -p /mnt/enc/boot;     mount "${TLOOP}p3" /mnt/enc/boot
mount -o ro "$SRC_BOOT" /mnt/src; rsync -aHAX /mnt/src/ /mnt/enc/boot/; umount /mnt/src
mkdir -p /mnt/enc/boot/efi; mount "${TLOOP}p2" /mnt/enc/boot/efi
[ -n "$SRC_ESP" ] && { mount -o ro "$SRC_ESP" /mnt/src; rsync -aHAX /mnt/src/ /mnt/enc/boot/efi/; umount /mnt/src; }
for d in proc sys dev run tmp; do mkdir -p "/mnt/enc/$d"; done; chmod 1777 /mnt/enc/tmp
KVER=$(ls /mnt/enc/lib/modules | sort -V | tail -1)
ln -sf "vmlinuz-$KVER"    /mnt/enc/boot/vmlinuz       # the extractor looks for /boot/vmlinuz
ln -sf "initrd.img-$KVER" /mnt/enc/boot/initrd.img
mkdir -p /mnt/enc/boot/lib/systemd                    # marker: makes Verda pick /boot as "root"

# fstab + crypttab
ESP_UUID=$(printf '%s' "$ESP_VOLID" | tr 'a-f' 'A-F'); ESP_UUID="${ESP_UUID:0:4}-${ESP_UUID:4:4}"
cat > /mnt/enc/etc/fstab <<FSTAB
/dev/mapper/cryptroot / ext4 errors=remount-ro 0 1
UUID=$BOOT_FS_UUID /boot ext4 defaults,nofail 0 2
UUID=$ESP_UUID /boot/efi vfat umask=0077,nofail 0 1
FSTAB
echo "cryptroot UUID=$LUKS_UUID none luks,initramfs,discard" > /mnt/enc/etc/crypttab

# First-boot: grow the encrypted root to fill the disk. Like boot_custom_os's
# firstboot growpart+resize2fs, but LUKS-aware (vda4 -> LUKS -> ext4) and using
# the disposable keyfile (so `cryptsetup resize` needs no passphrase). The
# keyfile + its keyslot are removed once done, so no unlock secret persists.
install -D -m600 "$GROWKEY" /mnt/enc/root/.growkey; rm -f "$GROWKEY"
mkdir -p /mnt/enc/usr/local/sbin
cat > /mnt/enc/usr/local/sbin/grow-cryptroot.sh <<'GROW'
#!/bin/sh
set -e
KEY=/root/.growkey
[ -f "$KEY" ] || exit 0
root=$(findmnt -n -o SOURCE /); name=${root#/dev/mapper/}
back=$(cryptsetup status "$name" | awk '/device:/{print $2}')   # e.g. /dev/vda4
disk=$(echo "$back" | sed -E 's/p?[0-9]+$//')                   # -> /dev/vda (or /dev/nvme0n1)
part=$(echo "$back" | grep -oE '[0-9]+$')                       # -> 4
growpart "$disk" "$part" || true                               # no-op if already full
cryptsetup resize "$name" --key-file "$KEY"
resize2fs "$root"
cryptsetup luksRemoveKey "$back" --key-file "$KEY" || true      # drop the disposable keyslot
shred -u "$KEY" 2>/dev/null || rm -f "$KEY"
GROW
chmod +x /mnt/enc/usr/local/sbin/grow-cryptroot.sh
cat > /mnt/enc/etc/systemd/system/grow-cryptroot.service <<'UNIT'
[Unit]
Description=Grow the encrypted root to fill the disk (first boot)
After=local-fs.target
ConditionPathExists=/root/.growkey
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/grow-cryptroot.sh
[Install]
WantedBy=multi-user.target
UNIT
mkdir -p /mnt/enc/etc/systemd/system/multi-user.target.wants
ln -sf ../grow-cryptroot.service /mnt/enc/etc/systemd/system/multi-user.target.wants/grow-cryptroot.service

# Install the attestation + unlock initramfs (separate file), then bake it
bash "$SCRIPT_DIR/attested_initramfs.sh" /mnt/enc
for d in /proc /sys /dev /dev/pts /run; do mount --bind $d "/mnt/enc$d"; done
chroot /mnt/enc env KVER="$KVER" DEBIAN_FRONTEND=noninteractive /bin/bash -eu -c '
  apt-get update -q
  apt-get install -y -q dropbear-initramfs cryptsetup-initramfs busybox cloud-guest-utils
  # Drop any host key the postinst baked into the image so every VM built from
  # it does not share one; init-top/00attestkey regenerates a fresh key in RAM
  # on every boot instead (see attested_initramfs.sh).
  rm -f /etc/dropbear/initramfs/dropbear_*_host_key
  update-initramfs -u -k "$KVER"'
umount -R /mnt/enc/proc /mnt/enc/sys /mnt/enc/dev /mnt/enc/run 2>/dev/null || true

# Export verifier artifacts (used by 03_attest_and_unlock.sh)
mkdir -p verify
cp /mnt/enc/boot/vmlinuz-"$KVER"    verify/vmlinuz
cp /mnt/enc/boot/initrd.img-"$KVER" verify/initrd.img
echo "$LUKS_UUID" > verify/luks_uuid; echo "$KVER" > verify/kver; printf '%s\n' "$CMDLINE" > verify/cmdline.txt
chown -R "${SUDO_USER:-$(id -un)}" verify

# Close up
umount -R /mnt/enc; cryptsetup close cryptroot; losetup -d "$TLOOP"; losetup -d "$SLOOP"; TLOOP=""; SLOOP=""
trap - EXIT
chmod a+rw "$ENCNAME"
echo "Image ready: $ENCNAME ($(du -h "$ENCNAME" | cut -f1))  LUKS_UUID=$LUKS_UUID  KVER=$KVER"
