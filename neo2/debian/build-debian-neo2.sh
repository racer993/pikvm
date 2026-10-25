#!/usr/bin/env bash
#
# build-debian-neo2.sh - build a plain Debian (default: 13 "trixie") arm64
# microSD image for the FriendlyELEC NanoPi NEO2 (Allwinner H5, 512 MB).
#
# Everything comes from the Debian archive:
#   * rootfs:      mmdebstrap (preferred) or debootstrap --foreign + qemu
#   * kernel:      linux-image-arm64 (mainline, ships sun50i-h5-nanopi-neo2.dtb)
#   * bootloader:  u-boot-sunxi  (/usr/lib/u-boot/nanopi_neo2/u-boot-sunxi-with-spl.bin)
#   * boot config: u-boot-menu   (/boot/extlinux/extlinux.conf, regenerated on
#                                 every kernel upgrade by its kernel hooks)
#
# Layout: MBR, partition 1 = ext4 root starting at 4 MiB, U-Boot at 8 KiB.
# First boot: SSH host keys generated, root partition grown to the full card.
#
# Run with --help for usage. Run with --dry-run first.
#
# Package / path names and how they were checked (2026-10, from a container
# that could NOT reach deb.debian.org; see neo2/debian/README.md):
#   * u-boot-sunxi target dir "nanopi_neo2" + file u-boot-sunxi-with-spl.bin:
#       checked in debian/targets.mk of u-boot 2025.01-3 (Debian packaging as
#       merged into Ubuntu 2025.01-3ubuntu4) and in the Ubuntu u-boot-sunxi .deb.
#   * u-boot-menu: config vars (U_BOOT_ROOT, U_BOOT_PARAMETERS, U_BOOT_FDT,
#       U_BOOT_FDT_DIR) checked in u-boot-menu 4.2.4 (Ubuntu rebuild of Debian).
#   * Debian kernel DTB dir /usr/lib/linux-image-<ver>/allwinner/...:
#       NOT checked against the trixie .deb (Debian convention; u-boot-menu's
#       own kernel hook uses /usr/lib/linux-image-<ver>). The script verifies
#       the generated extlinux.conf points at an existing DTB and aborts
#       otherwise, so a wrong guess fails the build instead of the boot.
#   * Package names (systemd-resolved, systemd-timesyncd, cloud-guest-utils,
#       fake-hwclock, libnss-mdns, ...): from knowledge of trixie, NOT checked
#       against the trixie archive. apt fails loudly if one is missing.

set -euo pipefail

PROG=${0##*/}

# ----------------------------------------------------------------- defaults --
HOSTNAME_NEW=neo2
NEW_USER=rolf
PUBKEY=""
PASSWORD_AUTH=no
SUITE=trixie
MIRROR=http://deb.debian.org/debian
DEVICE=""
IMAGE_FILE=""
IMAGE_SIZE=2G
WORKDIR=""
DRY_RUN=no
TIMEZONE=Europe/Berlin
LOCALE=en_US.UTF-8
ROOT_LABEL=neo2root
CREDS_FILE="$PWD/neo2-debian-credentials.txt"
MAX_DEVICE_BYTES=$((64 * 1024 * 1024 * 1024))   # 64 GiB (a "64 GB" card fits)
PART_START_SECTOR=8192                           # 4 MiB with 512-byte sectors
UBOOT_TARGET=nanopi_neo2
DTB_REL=allwinner/sun50i-h5-nanopi-neo2.dtb

# Overrides for testing the script against another archive (e.g. Ubuntu
# ports). Not needed for Debian; leave unset.
SECURITY_MIRROR=${NEO2_SECURITY_MIRROR-http://security.debian.org/debian-security}
COMPONENTS=${NEO2_COMPONENTS:-main}
KERNEL_PKG=${NEO2_KERNEL_PKG:-linux-image-arm64}
FDT_DIR=${NEO2_FDT_DIR:-/usr/lib/linux-image-}
KEYRING=${NEO2_KEYRING:-}

PACKAGES=(
  apt systemd-sysv udev dbus kmod netbase iproute2 iputils-ping procps less nano
  openssh-server openssh-sftp-server sudo
  systemd-timesyncd systemd-resolved avahi-daemon libnss-mdns
  ca-certificates locales tzdata
  e2fsprogs fdisk cloud-guest-utils fake-hwclock
  initramfs-tools zstd "$KERNEL_PKG" u-boot-sunxi u-boot-menu
)

# ------------------------------------------------------------------ helpers --
log()  { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo $PROG (--device /dev/sdX | --image-file out.img [--device /dev/sdX]) [options]

Target (at least one):
  --device /dev/sdX       microSD card in a USB reader (whole disk, TRAN=usb, <= 64 GiB).
                          Alone: partition + build directly onto the card.
                          With --image-file: build the image, then flash it to the card.
  --image-file FILE       build into a raw image file (must not exist yet)
  --image-size SIZE       size of the image file (default: $IMAGE_SIZE; root grows on first boot)

Options:
  --hostname NAME         default: $HOSTNAME_NEW
  --user NAME             regular sudo user, default: $NEW_USER
  --pubkey FILE           SSH public key (default: ~/.ssh/id_ed25519.pub, else the only ~/.ssh/*.pub)
  --password-auth         allow SSH password login for the regular user
  --no-password-auth      key-only SSH (default)
  --suite SUITE           default: $SUITE
  --mirror URL            default: $MIRROR
  --workdir DIR           build directory (default: mktemp under /var/tmp)
  --dry-run               print the plan and run the safety checks only; change nothing
  -h, --help              this help
EOF
}

# ------------------------------------------------------------- arg parsing --
need_arg() { [[ $# -ge 2 && -n $2 ]] || die "option $1 needs an argument"; }
while [[ $# -gt 0 ]]; do
  case $1 in
    --device)           need_arg "$@"; DEVICE=$2; shift 2 ;;
    --image-file)       need_arg "$@"; IMAGE_FILE=$2; shift 2 ;;
    --image-size)       need_arg "$@"; IMAGE_SIZE=$2; shift 2 ;;
    --hostname)         need_arg "$@"; HOSTNAME_NEW=$2; shift 2 ;;
    --user)             need_arg "$@"; NEW_USER=$2; shift 2 ;;
    --pubkey)           need_arg "$@"; PUBKEY=$2; shift 2 ;;
    --password-auth)    PASSWORD_AUTH=yes; shift ;;
    --no-password-auth) PASSWORD_AUTH=no; shift ;;
    --suite)            need_arg "$@"; SUITE=$2; shift 2 ;;
    --mirror)           need_arg "$@"; MIRROR=${2%/}; shift 2 ;;
    --workdir)          need_arg "$@"; WORKDIR=$2; shift 2 ;;
    --dry-run)          DRY_RUN=yes; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n $DEVICE || -n $IMAGE_FILE ]] || { usage >&2; die "need --device and/or --image-file"; }
[[ $HOSTNAME_NEW =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "invalid hostname: $HOSTNAME_NEW"
[[ $NEW_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ && $NEW_USER != root ]] || die "invalid user name: $NEW_USER"
[[ $SUITE =~ ^[a-z0-9-]+$ ]] || die "invalid suite: $SUITE"
[[ $MIRROR =~ ^https?://[^[:space:]]+$ ]] || die "invalid mirror URL: $MIRROR"
[[ $IMAGE_SIZE =~ ^[0-9]+[MG]$ ]] || die "--image-size must look like 2G or 1800M"
if [[ -n $IMAGE_FILE ]]; then
  [[ ! -e $IMAGE_FILE ]] || die "$IMAGE_FILE already exists; remove it or choose another name"
  IMAGE_FILE=$(realpath -m -- "$IMAGE_FILE")
  [[ -d ${IMAGE_FILE%/*} ]] || die "directory of $IMAGE_FILE does not exist"
fi

# Home of the human running the script (also under sudo).
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
  INVOKER=$SUDO_USER
  INVOKER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  INVOKER=$(id -un)
  INVOKER_HOME=$HOME
fi

# ------------------------------------------------------------ public key --
# Only *.pub files are ever opened; private keys are never read.
resolve_pubkey() {
  if [[ -z $PUBKEY ]]; then
    if [[ -f $INVOKER_HOME/.ssh/id_ed25519.pub ]]; then
      PUBKEY=$INVOKER_HOME/.ssh/id_ed25519.pub
    else
      local cands=()
      shopt -s nullglob
      cands=("$INVOKER_HOME"/.ssh/*.pub)
      shopt -u nullglob
      case ${#cands[@]} in
        0) die "no SSH public key found in $INVOKER_HOME/.ssh; pass --pubkey FILE" ;;
        1) PUBKEY=${cands[0]} ;;
        *) die "several public keys found (${cands[*]}); choose one with --pubkey FILE" ;;
      esac
    fi
  fi
  [[ -f $PUBKEY && -r $PUBKEY ]] || die "public key $PUBKEY not readable"
  [[ $PUBKEY == *.pub ]] || die "refusing $PUBKEY: the file name must end in .pub (never pass a private key)"
  if grep -q 'PRIVATE KEY' -- "$PUBKEY"; then
    die "$PUBKEY looks like a PRIVATE key; refusing"
  fi
  PUBKEY_LINE=$(grep -Ev '^[[:space:]]*(#|$)' -- "$PUBKEY" || true)
  [[ $(printf '%s\n' "$PUBKEY_LINE" | grep -c .) -eq 1 ]] || die "$PUBKEY must contain exactly one key line"
  [[ $PUBKEY_LINE =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] \
    || die "$PUBKEY does not look like an OpenSSH public key"
  if command -v ssh-keygen >/dev/null; then
    PUBKEY_FP=$(ssh-keygen -l -f "$PUBKEY") || die "ssh-keygen cannot parse $PUBKEY"
  else
    PUBKEY_FP="(ssh-keygen not installed; fingerprint not shown)"
  fi
}

# --------------------------------------------------------- device checks --
DEVICE_ID=""
check_device() {
  local dev=$1 type tran size node t mounts=() protected src
  [[ $dev == /dev/* && -b $dev ]] || die "$dev is not a block device"
  dev=$(realpath -- "$dev"); DEVICE=$dev
  type=$(lsblk -dno TYPE "$dev" 2>/dev/null) || die "lsblk cannot query $dev (no medium?)"
  [[ $type == disk ]] || die "$dev is a '$type', not a whole disk"
  tran=$(lsblk -dno TRAN "$dev" | tr -d ' ')
  [[ $tran == usb ]] || die "$dev has TRAN='${tran:-none}', only USB card readers (TRAN=usb) are accepted"
  size=$(lsblk -bdno SIZE "$dev" | tr -d ' ')
  [[ $size =~ ^[0-9]+$ && $size -gt 0 ]] || die "$dev: no medium / size 0 (card inserted?)"
  (( size <= MAX_DEVICE_BYTES )) || die "$dev is $((size / 1000000000)) GB, larger than the 64 GiB safety limit"

  # Refuse if the disk (or anything stacked on it) backs /, /boot, /home, ...
  for protected in / /boot /boot/efi /boot/firmware /home /usr /var; do
    src=$(findmnt -nro SOURCE --mountpoint "$protected" 2>/dev/null | head -n1 || true)
    [[ -n $src && -b $src ]] || continue
    if lsblk -nsrpo NAME "$src" 2>/dev/null | grep -qxF "$dev"; then
      die "$dev holds $protected ($src); refusing"
    fi
  done
  while read -r node; do
    [[ -n $node ]] || continue
    if grep -q "^${node}[[:space:]]" /proc/swaps; then die "$node is active swap; refusing"; fi
    if [[ -n $(ls -A "/sys/class/block/${node##*/}/holders" 2>/dev/null) ]]; then
      die "$node is in use by device-mapper/LVM/RAID (holders present); refusing"
    fi
    while read -r t; do
      [[ -n $t ]] || continue
      case $t in
        /|/boot|/boot/*|/home|/home/*|/usr|/usr/*|/var|/var/*)
          die "$node is mounted on $t; refusing" ;;
      esac
      mounts+=("$node on $t")
    done < <(findmnt -nro TARGET --source "$node" 2>/dev/null || true)
  done < <(lsblk -nrpo NAME "$dev")

  DEVICE_SIZE=$size
  DEVICE_ID=$(lsblk -dno SIZE,MODEL,SERIAL "$dev" | tr -s ' ')
  DEVICE_MOUNTS=("${mounts[@]}")
}

# ----------------------------------------------------------- tool checks --
HOST_ARCH=$(uname -m)
pick_bootstrapper() {
  if command -v mmdebstrap >/dev/null; then BOOTSTRAP=mmdebstrap
  elif command -v debootstrap >/dev/null; then BOOTSTRAP=debootstrap
  else BOOTSTRAP=""; fi
}
check_tools() {
  local missing=() t
  for t in sfdisk mkfs.ext4 losetup lsblk findmnt wipefs blockdev tar chroot dd partx; do
    command -v "$t" >/dev/null || missing+=("$t")
  done
  [[ -n $BOOTSTRAP ]] || missing+=("mmdebstrap-or-debootstrap")
  if [[ $HOST_ARCH != aarch64 ]]; then
    [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
      || missing+=("qemu-aarch64-binfmt (install qemu-user-static + binfmt-support)")
  fi
  [[ ${#missing[@]} -eq 0 ]] || die "missing tools: ${missing[*]}"
  if [[ -z $KEYRING ]]; then
    for t in /usr/share/keyrings/debian-archive-keyring.gpg /usr/share/keyrings/debian-archive-keyring.pgp; do
      if [[ -f $t ]]; then KEYRING=$t; break; fi
    done
  fi
  [[ -n $KEYRING && -e $KEYRING ]] || die "Debian archive keyring not found (install debian-archive-keyring)"
}

# ------------------------------------------------------------- preflight --
resolve_pubkey
pick_bootstrapper
if [[ -n $DEVICE ]]; then check_device "$DEVICE"; fi
DISK_ID=$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')
[[ $DISK_ID != 00000000 ]] || DISK_ID=4e454f32
PARTUUID="${DISK_ID}-01"
CMDLINE_EXTRA="rootwait ro console=ttyS0,115200n8"
EXTRA_SUITES=()
case $SUITE in sid|unstable|experimental|rc-buggy) ;; *) EXTRA_SUITES=("$SUITE-updates") ;; esac

print_plan() {
  cat <<EOF

================ NanoPi NEO2 Debian image plan ================
 suite / mirror   : $SUITE  $MIRROR  (components: $COMPONENTS)
 extra suites     : ${EXTRA_SUITES[*]:-none} ${SECURITY_MIRROR:+/ $SUITE-security from $SECURITY_MIRROR}
 bootstrapper     : ${BOOTSTRAP:-NONE FOUND}  (host arch $HOST_ARCH)
 hostname         : $HOSTNAME_NEW   (mDNS: $HOSTNAME_NEW.local)
 user             : $NEW_USER (groups: sudo) + root, random passwords -> $CREDS_FILE
 ssh key          : $PUBKEY
                    $PUBKEY_FP
 ssh password auth: $PASSWORD_AUTH   (root: prohibit-password)
 timezone/locale  : $TIMEZONE / $LOCALE
 kernel / u-boot  : $KERNEL_PKG / u-boot-sunxi ($UBOOT_TARGET), extlinux via u-boot-menu
 partition table  : MBR, disk id 0x$DISK_ID, p1 ext4 label '$ROOT_LABEL' from sector $PART_START_SECTOR (4 MiB)
 root=            : PARTUUID=$PARTUUID
 cmdline          : $CMDLINE_EXTRA
 image file       : ${IMAGE_FILE:-none}${IMAGE_FILE:+ ($IMAGE_SIZE)}
 target device    : ${DEVICE:-none}${DEVICE:+ ($DEVICE_ID)}
 packages         : ${PACKAGES[*]}

 steps:
   1. bootstrap arm64 rootfs into a work directory (${WORKDIR:-/var/tmp/neo2-debian.XXXXXX})
   2. configure it in a chroot (qemu): network, ssh, users, locale, first-boot units
   3. $( [[ -n $IMAGE_FILE ]] && echo "create $IMAGE_FILE, attach a loop device" || echo "unmount + wipe $DEVICE (after typed confirmation)" )
   4. zero first 4 MiB, sfdisk MBR, mkfs.ext4, copy rootfs
   5. dd u-boot-sunxi-with-spl.bin bs=1024 seek=8 conv=notrunc
EOF
  if [[ -n $IMAGE_FILE && -n $DEVICE ]]; then
    echo "   6. flash $IMAGE_FILE to $DEVICE (after typed confirmation)"
  fi
  echo "==============================================================="
  if [[ -n $DEVICE ]]; then
    echo
    lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL,SERIAL,FSTYPE,LABEL,MOUNTPOINT "$DEVICE"
    if [[ ${#DEVICE_MOUNTS[@]} -gt 0 ]]; then
      echo "(will be unmounted: ${DEVICE_MOUNTS[*]})"
    fi
  fi
  echo
}

print_plan
if [[ $DRY_RUN == yes ]]; then
  if (check_tools); then log "tool check OK"; else warn "tool check failed (see above)"; fi
  log "dry run: nothing was changed."
  exit 0
fi

[[ $(id -u) -eq 0 ]] || die "run as root (sudo) - or use --dry-run"
check_tools

confirm_device() {
  local ans
  [[ -t 0 || -r /dev/tty ]] || die "confirmation needs a terminal"
  echo
  warn "ALL DATA ON $DEVICE ($DEVICE_ID) WILL BE DESTROYED."
  read -r -p "Type the device path ($DEVICE) to confirm: " ans </dev/tty
  [[ $ans == "$DEVICE" ]] || die "confirmation did not match; aborting"
}
recheck_device() {
  local id
  id=$(lsblk -dno SIZE,MODEL,SERIAL "$DEVICE" 2>/dev/null | tr -s ' ') || die "$DEVICE vanished"
  [[ $id == "$DEVICE_ID" ]] || die "$DEVICE changed since confirmation ('$DEVICE_ID' -> '$id'); aborting"
  check_device "$DEVICE"
}
unmount_device() {
  local node t
  while read -r node; do
    while read -r t; do
      [[ -n $t ]] || continue
      log "unmounting $t ($node)"
      umount -- "$t"
    done < <(findmnt -nro TARGET --source "$node" 2>/dev/null | sort -r || true)
  done < <(lsblk -nrpo NAME "$DEVICE")
}

# Confirm up front so the long build can run unattended.
if [[ -n $DEVICE ]]; then confirm_device; fi

# --------------------------------------------------------------- cleanup --
MOUNTS=()        # stack of mountpoints to unmount (reverse order)
LOOPDEV=""
PARTLOOP=""
CREATED_WORKDIR=no
QEMU_COPIED=""
cleanup() {
  local rc=$? i
  set +e
  for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
    if mountpoint -q "${MOUNTS[i]}"; then
      umount "${MOUNTS[i]}" 2>/dev/null || umount -l "${MOUNTS[i]}"
    fi
  done
  [[ -n $PARTLOOP ]] && losetup -d "$PARTLOOP" 2>/dev/null
  [[ -n $LOOPDEV ]] && losetup -d "$LOOPDEV" 2>/dev/null
  if [[ $CREATED_WORKDIR == yes && -d $WORKDIR ]]; then
    # Never rm -rf while anything is still mounted below the workdir
    # (a leftover /dev bind mount would take the host's /dev with it).
    if findmnt -rno TARGET | grep -q "^$WORKDIR\(/\|$\)"; then
      warn "mounts remain below $WORKDIR; NOT deleting it"
    else
      rm -rf --one-file-system -- "$WORKDIR"
    fi
  fi
  if [[ $rc -ne 0 ]]; then
    warn "failed (exit $rc); cleaned up."
    if [[ -n $IMAGE_FILE && -f $IMAGE_FILE && ${IMAGE_DONE:-no} != yes ]]; then
      rm -f -- "$IMAGE_FILE"
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [[ -z $WORKDIR ]]; then
  WORKDIR=$(mktemp -d /var/tmp/neo2-debian.XXXXXX)
  CREATED_WORKDIR=yes
else
  mkdir -p -- "$WORKDIR"
  WORKDIR=$(realpath -- "$WORKDIR")
  [[ ! -e $WORKDIR/rootfs ]] || die "$WORKDIR/rootfs already exists"
fi
ROOTFS=$WORKDIR/rootfs
MNT=$WORKDIR/mnt
mkdir -p "$ROOTFS" "$MNT"

do_mount() { mount "$@"; MOUNTS+=("${*: -1}"); }
umount_top() {   # unmount the most recent N mounts
  local n=$1 i
  for ((i = 0; i < n; i++)); do
    umount "${MOUNTS[-1]}"
    unset 'MOUNTS[-1]'
  done
}

in_chroot() {
  chroot "$ROOTFS" /usr/bin/env -i \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true "$@"
}
chroot_mounts() {
  do_mount -t proc proc "$ROOTFS/proc"
  do_mount -t sysfs sysfs "$ROOTFS/sys"
  do_mount --bind /dev "$ROOTFS/dev"
  do_mount --bind /dev/pts "$ROOTFS/dev/pts"
  do_mount -t tmpfs tmpfs "$ROOTFS/run"
}

# Make the arm64 chroot executable on non-arm64 hosts when the binfmt entry
# lacks the F (fix-binary) flag.
ensure_qemu_in_chroot() {
  [[ $HOST_ARCH != aarch64 ]] || return 0
  local interp
  interp=$(sed -n 's/^interpreter //p' /proc/sys/fs/binfmt_misc/qemu-aarch64)
  if grep -q '^flags:.*F' /proc/sys/fs/binfmt_misc/qemu-aarch64; then return 0; fi
  [[ -e $ROOTFS$interp ]] && return 0
  mkdir -p "$ROOTFS${interp%/*}"
  cp -- "$interp" "$ROOTFS$interp"
  QEMU_COPIED=$interp
}

# ----------------------------------------------------- 1. bootstrap rootfs --
apt_lines() {
  echo "deb $MIRROR $SUITE $COMPONENTS"
  local s
  for s in "${EXTRA_SUITES[@]}"; do echo "deb $MIRROR $s $COMPONENTS"; done
  [[ -z $SECURITY_MIRROR || ${#EXTRA_SUITES[@]} -eq 0 ]] || echo "deb $SECURITY_MIRROR $SUITE-security $COMPONENTS"
}

if [[ $BOOTSTRAP == mmdebstrap ]]; then
  log "bootstrapping $SUITE arm64 with mmdebstrap (this takes a while under qemu)"
  pkgs=$(IFS=,; echo "${PACKAGES[*]}")
  mapfile -t mirrors < <(apt_lines)
  mmdebstrap --mode=root --architectures=arm64 --variant=minbase \
    --keyring="$KEYRING" --components="${COMPONENTS// /,}" \
    --aptopt='APT::Install-Recommends "false"' \
    --include="$pkgs" \
    "$SUITE" "$ROOTFS" "${mirrors[@]}"
  rm -f "$ROOTFS/etc/apt/apt.conf.d/99mmdebstrap" "$ROOTFS/etc/dpkg/dpkg.cfg.d/99mmdebstrap"
  ensure_qemu_in_chroot
  chroot_mounts
else
  log "bootstrapping $SUITE arm64 with debootstrap --foreign"
  debootstrap --arch=arm64 --foreign --variant=minbase --keyring="$KEYRING" \
    --components="${COMPONENTS// /,}" "$SUITE" "$ROOTFS" "$MIRROR"
  ensure_qemu_in_chroot
  in_chroot /debootstrap/debootstrap --second-stage
  apt_lines > "$ROOTFS/etc/apt/sources.list"
  printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
  chmod 755 "$ROOTFS/usr/sbin/policy-rc.d"
  cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
  chroot_mounts
  in_chroot apt-get update
  in_chroot apt-get install -y --no-install-recommends "${PACKAGES[@]}"
  in_chroot apt-get clean
  rm -f "$ROOTFS/usr/sbin/policy-rc.d"
fi

# ------------------------------------------------------ 2. configure rootfs --
log "configuring rootfs"
R=$ROOTFS

# apt sources (deb822). Signed-By only if the keyring file exists in the
# rootfs (debian-archive-keyring ships .gpg and/or .pgp depending on version).
rm -f "$R/etc/apt/sources.list"
signed_by=""
for k in /usr/share/keyrings/debian-archive-keyring.pgp /usr/share/keyrings/debian-archive-keyring.gpg; do
  if [[ -e $R$k ]]; then signed_by="Signed-By: $k"$'\n'; break; fi
done
{
  printf 'Types: deb\nURIs: %s\nSuites: %s%s\nComponents: %s\n%s' \
    "$MIRROR" "$SUITE" "${EXTRA_SUITES[*]:+ ${EXTRA_SUITES[*]}}" "$COMPONENTS" "$signed_by"
  if [[ -n $SECURITY_MIRROR && ${#EXTRA_SUITES[@]} -gt 0 ]]; then
    printf '\nTypes: deb\nURIs: %s\nSuites: %s-security\nComponents: %s\n%s' \
      "$SECURITY_MIRROR" "$SUITE" "$COMPONENTS" "$signed_by"
  fi
} > "$R/etc/apt/sources.list.d/debian.sources"

# hostname / hosts
echo "$HOSTNAME_NEW" > "$R/etc/hostname"
cat > "$R/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$HOSTNAME_NEW
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

# fstab
cat > "$R/etc/fstab" <<EOF
# <file system>		<mount point>	<type>	<options>			<dump>	<pass>
PARTUUID=$PARTUUID	/		ext4	defaults,noatime,errors=remount-ro	0	1
EOF

# timezone + locale
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$R/etc/localtime"
echo "$TIMEZONE" > "$R/etc/timezone"
in_chroot dpkg-reconfigure -f noninteractive tzdata
sed -i "s/^# *\($LOCALE .*\)/\1/" "$R/etc/locale.gen"
grep -q "^$LOCALE " "$R/etc/locale.gen" || echo "$LOCALE UTF-8" >> "$R/etc/locale.gen"
in_chroot locale-gen
printf 'LANG=%s\n' "$LOCALE" > "$R/etc/default/locale"

# network: DHCP on the first wired NIC (end0 on mainline DT boards), matched by type
cat > "$R/etc/systemd/network/10-wired.network" <<'EOF'
[Match]
Type=ether
Name=!veth* !docker* !br-*

[Network]
DHCP=yes
LLMNR=no
MulticastDNS=no

[DHCPv4]
UseDomains=yes
EOF
mkdir -p "$R/etc/systemd/resolved.conf.d" "$R/etc/systemd/system/systemd-networkd-wait-online.service.d"
printf '[Resolve]\n# avahi-daemon owns mDNS (port 5353)\nMulticastDNS=no\nLLMNR=no\n' \
  > "$R/etc/systemd/resolved.conf.d/10-neo2.conf"
printf '[Service]\nExecStart=\nExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=30\n' \
  > "$R/etc/systemd/system/systemd-networkd-wait-online.service.d/10-neo2.conf"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$R/etc/resolv.conf"

# ssh: key-only by default, host keys generated on first boot
mkdir -p "$R/etc/ssh/sshd_config.d"
{
  echo "# written by $PROG"
  echo "PermitRootLogin prohibit-password"
  if [[ $PASSWORD_AUTH == yes ]]; then
    echo "PasswordAuthentication yes"
  else
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
  fi
} > "$R/etc/ssh/sshd_config.d/10-neo2.conf"
rm -f "$R"/etc/ssh/ssh_host_*
cat > "$R/etc/systemd/system/neo2-ssh-hostkeys.service" <<'EOF'
[Unit]
Description=Generate missing SSH host keys
Before=ssh.service ssh.socket
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
ExecStartPost=/bin/sync

[Install]
WantedBy=multi-user.target
EOF

# first-boot: grow the root partition + filesystem to the whole card
mkdir -p "$R/var/lib/neo2"
touch "$R/var/lib/neo2/growroot-pending"
cat > "$R/usr/local/sbin/neo2-growroot" <<'EOF'
#!/bin/sh
# Grow the root partition (growpart, cloud-guest-utils) and ext4 online.
set -eu
majmin=$(findmnt -nro MAJ:MIN /)
part=$(readlink -f "/sys/dev/block/$majmin")
dev=/dev/${part##*/}
num=$(cat "$part/partition")
disk=/dev/$(basename "$(dirname "$part")")
echo "growing $dev (partition $num of $disk)"
rc=0; growpart "$disk" "$num" || rc=$?
[ "$rc" -le 1 ] || exit "$rc"      # 1 = NOCHANGE
resize2fs "$dev"
rm -f /var/lib/neo2/growroot-pending
EOF
chmod 755 "$R/usr/local/sbin/neo2-growroot"
cat > "$R/etc/systemd/system/neo2-growroot.service" <<'EOF'
[Unit]
Description=Grow root partition to fill the SD card (first boot)
ConditionPathExists=/var/lib/neo2/growroot-pending
After=systemd-remount-fs.service
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/neo2-growroot

[Install]
WantedBy=multi-user.target
EOF

# no RTC: fake-hwclock (restores last saved time at boot), seeded with build time;
# systemd-timesyncd also keeps /var/lib/systemd/timesync/clock.
date -u '+%Y-%m-%d %H:%M:%S' > "$R/etc/fake-hwclock.data"

# serial console + boot configuration (u-boot-menu -> /boot/extlinux/extlinux.conf)
printf 'root=PARTUUID=%s %s\n' "$PARTUUID" "$CMDLINE_EXTRA" > "$R/etc/kernel/cmdline"
cat >> "$R/etc/default/u-boot" <<EOF

# --- NanoPi NEO2 settings written by $PROG ---
U_BOOT_ROOT="root=PARTUUID=$PARTUUID"
U_BOOT_PARAMETERS="$CMDLINE_EXTRA"
U_BOOT_FDT_DIR="$FDT_DIR"
U_BOOT_FDT="$DTB_REL"
U_BOOT_TIMEOUT="20"
U_BOOT_MENU_LABEL="Debian $SUITE"
EOF
in_chroot u-boot-update

# services
in_chroot systemctl enable systemd-networkd systemd-resolved systemd-timesyncd \
  ssh avahi-daemon neo2-ssh-hostkeys.service neo2-growroot.service \
  serial-getty@ttyS0.service
# fake-hwclock >= 0.12 ships fake-hwclock-load.service + fake-hwclock-save.timer
# (fake-hwclock.service is masked there); older versions ship fake-hwclock.service.
fhc=()
for u in fake-hwclock-load.service fake-hwclock-save.timer; do
  if [[ -e $R/usr/lib/systemd/system/$u || -e $R/lib/systemd/system/$u ]]; then fhc+=("$u"); fi
done
[[ ${#fhc[@]} -gt 0 ]] || fhc=(fake-hwclock.service)
in_chroot systemctl enable "${fhc[@]}" || warn "could not enable ${fhc[*]}"
in_chroot systemctl mask systemd-firstboot.service >/dev/null 2>&1 || true

# users + credentials
gen_pw() { head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20; }
ROOT_PW=$(gen_pw)
USER_PW=$(gen_pw)
in_chroot useradd -m -s /bin/bash -G sudo "$NEW_USER"
printf 'root:%s\n%s:%s\n' "$ROOT_PW" "$NEW_USER" "$USER_PW" | in_chroot chpasswd
install_key() {   # $1 = home dir inside rootfs, $2 = owner
  install -d -m 700 "$R$1/.ssh"
  printf '%s\n' "$PUBKEY_LINE" > "$R$1/.ssh/authorized_keys"
  chmod 600 "$R$1/.ssh/authorized_keys"
  in_chroot chown -R "$2:$2" "$1/.ssh"
}
install_key /root root
install_key "/home/$NEW_USER" "$NEW_USER"

# unique identity per board
: > "$R/etc/machine-id"
rm -f "$R/var/lib/dbus/machine-id"
rm -f "$R"/var/lib/apt/lists/*_Packages* "$R"/var/lib/apt/lists/*_Release* "$R"/var/lib/apt/lists/*_InRelease 2>/dev/null || true
in_chroot apt-get clean

# ------------------------------------------------------- verify the result --
UBOOT_BIN=$R/usr/lib/u-boot/$UBOOT_TARGET/u-boot-sunxi-with-spl.bin
if [[ ! -f $UBOOT_BIN ]]; then
  ls "$R/usr/lib/u-boot/" >&2 || true
  die "missing $UBOOT_BIN (u-boot-sunxi target name changed?)"
fi
UBOOT_SIZE=$(stat -c %s "$UBOOT_BIN")
(( UBOOT_SIZE + 8192 <= PART_START_SECTOR * 512 )) || die "u-boot ($UBOOT_SIZE bytes) does not fit before the 4 MiB partition"
EXTLINUX=$R/boot/extlinux/extlinux.conf
[[ -f $EXTLINUX ]] || die "u-boot-update did not create $EXTLINUX"
grep -q "root=PARTUUID=$PARTUUID" "$EXTLINUX" || die "extlinux.conf lacks root=PARTUUID=$PARTUUID"
grep -q 'console=ttyS0,115200' "$EXTLINUX" || die "extlinux.conf lacks the serial console"
kpath=$(awk '$1=="linux"{print $2; exit}' "$EXTLINUX")
[[ -n $kpath && -f $R$kpath ]] || die "extlinux.conf kernel '$kpath' not found in rootfs"
fdt=$(awk '$1=="fdt"||$1=="fdtdir"{print $1" "$2; exit}' "$EXTLINUX")
case ${fdt%% *} in
  fdt)    dtb=${fdt#* } ;;
  fdtdir) dtb=${fdt#* }; dtb=${dtb%/}/$DTB_REL ;;
  *)      die "extlinux.conf has no fdt/fdtdir line" ;;
esac
[[ -f $R$dtb ]] || die "DTB $dtb referenced by extlinux.conf does not exist in rootfs"
log "verified: u-boot $UBOOT_SIZE bytes, kernel $kpath, dtb $dtb"

# leave the chroot
umount_top 5
if [[ -n $QEMU_COPIED ]]; then rm -f -- "$R$QEMU_COPIED"; fi
ROOTFS_KB=$(du -sxk "$R" | cut -f1)
log "rootfs size: $((ROOTFS_KB / 1024)) MiB"

# --------------------------------------------- 3./4./5. write the medium --
write_medium() {   # $1 = whole-disk block device (loop or card)
  local disk=$1 part="" i
  log "writing partition table + filesystem to $disk"
  wipefs -a -q "$disk"
  dd if=/dev/zero of="$disk" bs=1M count=4 conv=fsync status=none
  sfdisk --quiet --wipe always "$disk" <<EOF
label: dos
label-id: 0x$DISK_ID
unit: sectors

start=$PART_START_SECTOR, type=83, bootable
EOF
  blockdev --rereadpt "$disk" 2>/dev/null || partx -u "$disk" || true
  if command -v udevadm >/dev/null; then udevadm settle || true; fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    part=$(lsblk -nrpo NAME,TYPE "$disk" | awk '$2=="part"{print $1; exit}')
    [[ -n $part && -b $part ]] && break
    sleep 1
  done
  if [[ -z $part || ! -b $part ]]; then
    # containers without udev/devtmpfs partition nodes: map p1 via an offset loop
    [[ $disk == /dev/loop* ]] || die "partition on $disk did not appear"
    PARTLOOP=$(losetup -f --show -o $((PART_START_SECTOR * 512)) "$disk")
    part=$PARTLOOP
  fi
  mkfs.ext4 -q -F -L "$ROOT_LABEL" "$part"
  do_mount "$part" "$MNT"
  log "copying rootfs ($((ROOTFS_KB / 1024)) MiB)"
  tar -C "$R" --numeric-owner --xattrs --xattrs-include='*' --acls -cf - . \
    | tar -C "$MNT" --numeric-owner --xattrs --xattrs-include='*' --acls -xpf -
  sync
  umount_top 1
  if [[ -n $PARTLOOP ]]; then losetup -d "$PARTLOOP"; PARTLOOP=""; fi
  log "writing U-Boot ($UBOOT_TARGET) at 8 KiB"
  dd if="$UBOOT_BIN" of="$disk" bs=1024 seek=8 conv=notrunc,fsync status=none
  sync
}

if [[ -n $IMAGE_FILE ]]; then
  truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"
  img_bytes=$(stat -c %s "$IMAGE_FILE")
  (( img_bytes / 1024 > ROOTFS_KB + ROOTFS_KB / 4 + 4096 )) \
    || die "--image-size $IMAGE_SIZE too small for a $((ROOTFS_KB / 1024)) MiB rootfs"
  LOOPDEV=$(losetup -f --show -P "$IMAGE_FILE")
  write_medium "$LOOPDEV"
  losetup -d "$LOOPDEV"; LOOPDEV=""
  IMAGE_DONE=yes
  [[ -z ${SUDO_USER:-} ]] || chown "$SUDO_USER:" "$IMAGE_FILE"
  log "image ready: $IMAGE_FILE"
  if [[ -n $DEVICE ]]; then
    recheck_device
    (( img_bytes <= DEVICE_SIZE )) || die "image is larger than $DEVICE"
    unmount_device
    log "flashing $IMAGE_FILE to $DEVICE"
    wipefs -a -q "$DEVICE"
    dd if="$IMAGE_FILE" of="$DEVICE" bs=4M conv=fsync status=progress
    sync
    blockdev --rereadpt "$DEVICE" 2>/dev/null || true
  fi
else
  recheck_device
  unmount_device
  write_medium "$DEVICE"
fi

# ----------------------------------------------------------- credentials --
if [[ -e $CREDS_FILE ]]; then
  mv -- "$CREDS_FILE" "$CREDS_FILE.$(date +%Y%m%d-%H%M%S).bak"
fi
(
  umask 077
  cat > "$CREDS_FILE" <<EOF
# NanoPi NEO2 Debian $SUITE - generated $(date -Is) by $PROG
hostname: $HOSTNAME_NEW   (ssh $NEW_USER@$HOSTNAME_NEW.local)
root password: $ROOT_PW
$NEW_USER password: $USER_PW
ssh key: $PUBKEY_FP
ssh password auth: $PASSWORD_AUTH
root PARTUUID: $PARTUUID
EOF
)
chmod 600 "$CREDS_FILE"
[[ $INVOKER == root ]] || chown "$INVOKER:" "$CREDS_FILE"

log "done. credentials: $CREDS_FILE (mode 600)"
log "insert the card, connect Ethernet, power on; after 1-3 min: ssh $NEW_USER@$HOSTNAME_NEW.local"
