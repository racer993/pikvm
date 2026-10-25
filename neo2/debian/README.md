# Plain Debian 13 (trixie) for the NanoPi NEO2

`build-debian-neo2.sh` builds a minimal, plain Debian arm64 system for the
FriendlyELEC NanoPi NEO2 (Allwinner H5, 512 MB RAM, Gigabit Ethernet,
microSD boot only). It uses only Debian's own packages. No Armbian and no
vendor kernel.

| Part        | Source                                                                 |
|-------------|------------------------------------------------------------------------|
| rootfs      | `mmdebstrap` (preferred) or `debootstrap --foreign`, arm64 via qemu    |
| kernel      | `linux-image-arm64` (mainline; DTB `allwinner/sun50i-h5-nanopi-neo2.dtb`) |
| bootloader  | `u-boot-sunxi`: `/usr/lib/u-boot/nanopi_neo2/u-boot-sunxi-with-spl.bin` at 8 KiB |
| boot menu   | `u-boot-menu`: `/boot/extlinux/extlinux.conf`, rebuilt on every kernel upgrade |
| network     | systemd-networkd, DHCP on the first wired NIC (`Type=ether`, usually `end0`), systemd-resolved |
| discovery   | avahi-daemon + libnss-mdns, so the board answers as `neo2.local` |
| time        | systemd-timesyncd + fake-hwclock (the board has no RTC) |
| console     | serial `ttyS0` at 115200 8N1 (kernel console + getty) |

What the card looks like:

* MBR. Partition 1 is ext4 with label `neo2root` and starts at 4 MiB. U-Boot sits at 8 KiB.
* `fstab` and the kernel `root=` both use `PARTUUID=<diskid>-01`.
* SSH host keys are **not** in the image. Each board generates its own on first boot.
* On first boot, `neo2-growroot.service` grows the root partition and filesystem to fill the card (growpart + resize2fs).
* `/etc/machine-id` is empty, so each board gets its own ID and DHCP DUID.
* User `rolf` (in group `sudo`) and `root` both get your SSH public key. Both get random passwords, written to `./neo2-debian-credentials.txt` with mode 600. Use them for `sudo` and for the serial console.
* sshd allows key login only: `PermitRootLogin prohibit-password` and `PasswordAuthentication no`. Pass `--password-auth` to allow password login for the regular user.
* Timezone is Europe/Berlin and the locale is en_US.UTF-8.

## Prerequisites (on your Linux PC)

Debian/Ubuntu package names:

```sh
sudo apt install mmdebstrap qemu-user-static binfmt-support debian-archive-keyring \
                 fdisk e2fsprogs util-linux
# fallback instead of mmdebstrap: debootstrap
```

* On Debian 13 hosts, `qemu-user-static` may be a transitional package for `qemu-user` + `qemu-user-binfmt`. Either works. The script needs `/proc/sys/fs/binfmt_misc/qemu-aarch64` to exist. You do not need it on an arm64 host.
* You do not need `dosfstools`: there is no FAT boot partition.
* You need a USB microSD reader. The script only accepts whole disks with `TRAN=usb` and at most 64 GiB. Built-in readers (`/dev/mmcblk*`) are refused on purpose.
* You need about 2 GB free in `/var/tmp`, or set another place with `--workdir`. You also need network access to `deb.debian.org`.

## Usage

Always run a dry run first. It needs no root, changes nothing, runs the device safety checks and prints the plan:

```sh
./build-debian-neo2.sh --device /dev/sdX --dry-run
```

To build straight onto the card:

```sh
sudo ./build-debian-neo2.sh --device /dev/sdX
```

To build an image file, keep it, and optionally flash it:

```sh
sudo ./build-debian-neo2.sh --image-file neo2-trixie.img                    # image only
sudo ./build-debian-neo2.sh --image-file neo2-trixie.img --device /dev/sdX  # image + flash
```

Other options:

```
--hostname neo2   --user rolf   --pubkey ~/.ssh/id_ed25519.pub
--password-auth | --no-password-auth (default)
--suite trixie    --mirror http://deb.debian.org/debian
--image-size 2G   --workdir DIR
```

If you omit `--pubkey`, the script uses `~/.ssh/id_ed25519.pub` of the user who ran sudo. If that file does not exist, it uses the only `~/.ssh/*.pub`. If there are several, it stops and asks you to choose one. It only ever opens `*.pub` files.

Before it writes to a device, the script:

1. Shows `lsblk`.
2. Asks you to type the device path. It asks once at the start, so the long build can run unattended afterwards.
3. Checks the device again just before writing: same size, model and serial, and still not holding `/`, `/boot` or `/home`.
4. Unmounts any partitions of the card.

A trap cleans up the chroot bind mounts, the build mounts and the loop devices if anything fails.

Expect the build to take about 10 to 30 minutes, mostly for running the arm64 package scripts under qemu.

## First boot

1. Insert the card, connect Ethernet, then connect power.
2. The first boot takes 1 to 3 minutes. During it the board grows the root filesystem, generates SSH host keys, creates a machine ID and gets a DHCP lease.
3. Log in:
   ```sh
   ssh rolf@neo2.local
   ```
   You can use `ssh root@neo2.local` too. Both log in with your key.
4. Run `sudo apt update && sudo apt full-upgrade`. The `sudo` password is in `neo2-debian-credentials.txt`.

The board's SSH host key is new for every build. If you have used the name `neo2.local` before, clear the old entry first:
`ssh-keygen -R neo2.local`.

## Finding the IP address

* `ping neo2.local`, or `avahi-resolve -n neo2.local`. Your PC needs mDNS (nss-mdns) for this.
* Check your router's DHCP lease list for the hostname `neo2`.
* `sudo nmap -sn 192.168.1.0/24`. On a DT board the MAC address is derived from the H5 chip ID, so it stays the same across reboots.
* Use the serial console (below) and run `ip -br addr`.

## Troubleshooting with the serial console

The NEO2 has a 3-pin UART header (GND, TX, RX) next to the USB port. Use a 3.3 V USB-TTL adapter: cross TX and RX, and do **not** connect VCC. Then run:

```sh
picocom -b 115200 /dev/ttyUSB0      # or: screen /dev/ttyUSB0 115200
```

| What you see | Likely cause |
|--------------|--------------|
| No output at all | U-Boot was not written, or the card is bad. Rebuild and check the line "writing U-Boot". |
| U-Boot prints but `Retrieving file: /boot/extlinux/extlinux.conf` fails | The partition is not bootable or not ext4. Check with `fdisk -l` on the PC. |
| Kernel boots, then `Waiting for root device PARTUUID=...` | The PARTUUID does not match. Compare `blkid` on the PC with `/boot/extlinux/extlinux.conf`. |
| Login prompt but no network | Run `networkctl status` and `journalctl -u systemd-networkd`. |

You can log in on the serial console as `root` with the password from the credentials file. Useful checks:

```sh
systemctl --failed
journalctl -b -u neo2-growroot -u neo2-ssh-hostkeys
cat /boot/extlinux/extlinux.conf
```

At the U-Boot prompt, press a key to stop autoboot. The extlinux menu waits 2 seconds, so you can pick the recovery entry.

## Notes

* Kernel updates run `u-boot-update` through `/etc/kernel/postinst.d/zz-u-boot-menu`. Boot settings live at the end of `/etc/default/u-boot`.
* The image does not reflash U-Boot when `u-boot-sunxi` is upgraded. If you ever want to reflash it:
  `sudo dd if=/usr/lib/u-boot/nanopi_neo2/u-boot-sunxi-with-spl.bin of=/dev/mmcblk0 bs=1024 seek=8 conv=notrunc,fsync`
* There is no swap. With 512 MB RAM, consider `zram-tools` if you run heavier workloads.
