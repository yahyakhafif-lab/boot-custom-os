# boot_custom_os

Replace the OS on a running KVM/CC VM that uses **direct kernel boot**
(QEMU `-kernel`/`-initrd`/`-append`, no GRUB).

## How it works

1. `dropbear-initramfs` is installed on the running VM and a `99-pause` hook
   is added that keeps the VM in the initramfs indefinitely — `eth0` gets a
   DHCP address and dropbear listens on port 22, but `/dev/vda` is never
   mounted.
2. The VM is powered off via sysrq; the user Starts it from Verda. The host
   extracts the updated initrd from `/boot` and boots into the initramfs SSH
   environment where `/dev/vda` is free.
3. The new OS image is streamed directly from the local machine into
   `/dev/vda` via `gzip | ssh | dd`. No intermediate copy on the remote.
4. The VM is powered off again via sysrq; the user Starts it from Verda. The
   host extracts the new kernel/initrd from the flashed disk and boots the
   new OS.

## Important: CC VMs cannot reboot from inside

Confidential Computing VMs do not support in-guest reboot. Scripts power off
the VM with `echo o > /proc/sysrq-trigger` (sysrq poweroff), but **a manual
Start from the Verda console is always required** to bring the VM back up.
This applies twice: once to enter initramfs SSH mode, and once after flashing
to boot the new OS.

## Prerequisites

Install the following on the **local** machine:

```bash
sudo apt-get install -y libguestfs-tools qemu-utils pv
```

## Configuration

```bash
cp .env_sample .env
```

Edit `.env`: set `REMOTE` to `root@<IP>`. `SSH_KEY` defaults to `~/.ssh/id_ed25519.pub`.

## Steps

### 0. Build the OS image

```bash
sudo bash 00_build_image.sh
```

Produces `questing-server-raw.img` (~3.5 GiB raw, ~650 MB compressed):
Ubuntu 25.10 with SSH key injected, DHCP networking, cloud-init disabled,
and a first-boot service that runs `growpart`+`resize2fs` to fill the disk.

### 1. Set up initramfs SSH (once per machine, or after a kernel upgrade)

```bash
./01_setup_initramfs_ssh.sh
```

Installs `dropbear-initramfs`, copies SSH authorized keys, rebuilds
`/boot/initrd.img` with dropbear + the `99-pause` hook, and powers off the
VM. When prompted, **Start the VM** from the Verda console. The script waits
until dropbear answers on port 22 and exits with the VM ready to flash.

### 2. Flash the new OS

```bash
./02_flash.sh
```

Verifies `/dev/vda` is unmounted, streams the image, and triggers an
in-guest poweroff. When prompted, **Start the VM** from the Verda console.
The script waits for SSH on the new OS and reports success.
