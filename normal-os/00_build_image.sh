#!/bin/bash
# Downloads Ubuntu 25.10 cloud image, injects SSH key, network config,
# and first-boot partition resize. Outputs a raw image ready for dd.
#
# Requires: source .env (must set SSH_KEY)
# Requires: libguestfs-tools, qemu-utils
set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: run as root (sudo $0)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

if [ -z "$SSH_KEY" ]; then
  echo "Error: SSH_KEY is not set. Run: source .env" >&2
  exit 1
fi

for cmd in virt-customize qemu-img; do
  command -v "$cmd" &>/dev/null || {
    echo "Error: $cmd not found. Install: apt-get install libguestfs-tools qemu-utils" >&2
    exit 1
  }
done

# Define Ubuntu 25.10 cloud image names
IMAGENAME=questing-server-cloudimg-amd64.img
RAWNAME=questing-server-raw.img

# Download cloud image
wget -O $IMAGENAME https://cloud-images.ubuntu.com/questing/current/$IMAGENAME

# Customize image
virt-customize -a $IMAGENAME \
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
  --run-command 'sed -i "s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"net.ifnames=0 biosdevname=0 fsck.mode=auto fsck.repair=yes\"/" /etc/default/grub' \
  --run-command 'update-grub' \
  --run-command 'systemctl disable cloud-init cloud-init-local cloud-config cloud-final' \
  --firstboot-command 'ROOT_DEV=$(findmnt -n -o SOURCE /); DISK=$(lsblk -n -o PKNAME $ROOT_DEV); PARTNUM=$(echo $ROOT_DEV | grep -o "[0-9]*$"); growpart /dev/$DISK $PARTNUM && resize2fs $ROOT_DEV' \
  --truncate /etc/machine-id

# Convert to raw for dd
qemu-img convert -f qcow2 -O raw $IMAGENAME $RAWNAME
chmod a+rw "$IMAGENAME" "$RAWNAME"

echo "Image ready: $RAWNAME ($(du -h $RAWNAME | cut -f1))"
