#!/usr/bin/env bash
# flash-neo2.sh - provision a headless, SSH-ready Armbian (Debian trixie
# Minimal) microSD card for a FriendlyELEC NanoPi NEO2.
#
# Linux only (the Armbian root filesystem is ext4).
# Run as a normal user with sudo rights; privileged steps call sudo.
#
#   ./flash-neo2.sh --device /dev/sdX --dry-run      # print the plan only
#   ./flash-neo2.sh --device /dev/sdX                # download, flash, configure
#   ./flash-neo2.sh --device /dev/sdX --image F.img.xz --sha F.img.xz.sha
#   ./flash-neo2.sh --device /dev/sdX --no-flash     # re-configure a flashed card
#
# See ./README.md for details.

set -euo pipefail

# ---------------------------------------------------------------- defaults
BOARD="nanopineo2"
IMAGE_URL="https://dl.armbian.com/${BOARD}/Trixie_current_minimal"
ARMBIAN_KEY_URL="https://apt.armbian.com/armbian.key"
DEVICE=""
IMAGE=""
SHA_FILE=""
HOSTNAME_NEW="neo2"
USERNAME="rolf"
REALNAME=""
PUBKEY=""
TIMEZONE="Europe/Berlin"
LOCALE="en_US.UTF-8"
PASSWORD_AUTH="no"          # key-only by default
CACHE_DIR="./images"
CRED_FILE="./neo2-credentials.txt"
MNT="/mnt/neo2"
DRY_RUN=0
DO_FLASH=1
VERIFY_WRITE=0
MAX_BYTES=$((64 * 1000 * 1000 * 1000))

# ---------------------------------------------------------------- helpers
log()  { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33mWARN:\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31mERROR:\e[0m %s\n' "$*" >&2; exit 1; }

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# run CMD...: execute, or only print it in dry-run mode
run() {
	if ((DRY_RUN)); then
		printf '    [dry-run] %s\n' "$*"
	else
		"$@"
	fi
}

# put_file DEST MODE: write stdin to DEST (inside the mounted image) as root
put_file() {
	local dest=$1 mode=$2 content
	content=$(cat)
	if ((DRY_RUN)); then
		printf '    [dry-run] write %s (mode %s)\n' "$dest" "$mode"
		return
	fi
	$SUDO mkdir -p "$(dirname "$dest")"
	printf '%s\n' "$content" | $SUDO tee "$dest" >/dev/null
	$SUDO chmod "$mode" "$dest"
	$SUDO chown 0:0 "$dest"
}

usage() {
	sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
	cat <<-EOF

	Options:
	  --device DEV         target block device, e.g. /dev/sdb (required)
	  --image FILE         local Armbian image (.img or .img.xz); default: download
	  --sha FILE           checksum file for --image (default: FILE.sha if present)
	  --url URL            image download URL (default: $IMAGE_URL)
	  --hostname NAME      default: $HOSTNAME_NEW
	  --user NAME          regular user, default: $USERNAME
	  --realname NAME      default: capitalised user name
	  --pubkey FILE        SSH public key (default: ~/.ssh/id_ed25519.pub, else the only ~/.ssh/*.pub)
	  --password-auth      keep SSH password authentication enabled
	  --no-password-auth   key-only SSH (default)
	  --timezone TZ        default: $TIMEZONE
	  --locale LOCALE      default: $LOCALE
	  --credentials FILE   default: $CRED_FILE
	  --no-flash           skip download/flash; only configure an already flashed card
	  --verify-write       read the written image back and compare hashes
	  --dry-run            print the plan, change nothing
	  -h, --help
	EOF
}

# ---------------------------------------------------------------- arguments
while (($#)); do
	case $1 in
		--device)          DEVICE=$2; shift ;;
		--image)           IMAGE=$2; shift ;;
		--sha)             SHA_FILE=$2; shift ;;
		--url)             IMAGE_URL=$2; shift ;;
		--hostname)        HOSTNAME_NEW=$2; shift ;;
		--user)            USERNAME=$2; shift ;;
		--realname)        REALNAME=$2; shift ;;
		--pubkey)          PUBKEY=$2; shift ;;
		--password-auth)   PASSWORD_AUTH="yes" ;;
		--no-password-auth) PASSWORD_AUTH="no" ;;
		--timezone)        TIMEZONE=$2; shift ;;
		--locale)          LOCALE=$2; shift ;;
		--credentials)     CRED_FILE=$2; shift ;;
		--no-flash)        DO_FLASH=0 ;;
		--verify-write)    VERIFY_WRITE=1 ;;
		--dry-run)         DRY_RUN=1 ;;
		-h|--help)         usage; exit 0 ;;
		*)                 die "unknown option: $1 (see --help)" ;;
	esac
	shift
done

[[ $(uname -s) == Linux ]] || die "Linux only (the Armbian rootfs is ext4)."
[[ -n $DEVICE ]] || die "--device is required (see lsblk -o NAME,SIZE,TYPE,TRAN,MODEL)"
[[ $HOSTNAME_NEW =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "invalid hostname: $HOSTNAME_NEW"
[[ $USERNAME =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "invalid user name: $USERNAME"
[[ -z $REALNAME ]] && REALNAME=${USERNAME^}
[[ $REALNAME =~ ^[A-Za-z0-9\ ._-]+$ ]] || die "real name may only contain letters, digits, space, . _ -"

for cmd in lsblk findmnt blkid wipefs dd xz sha256sum openssl ssh-keygen curl partprobe; do
	command -v "$cmd" >/dev/null || die "missing required command: $cmd"
done

# ---------------------------------------------------------------- step 1: inputs
# The invoking user's home, also when started via sudo.
USER_HOME=$HOME
[[ -n ${SUDO_USER:-} ]] && USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)

if [[ -z $PUBKEY ]]; then
	if [[ -f $USER_HOME/.ssh/id_ed25519.pub ]]; then
		PUBKEY=$USER_HOME/.ssh/id_ed25519.pub
	else
		shopt -s nullglob
		keys=("$USER_HOME"/.ssh/*.pub)
		shopt -u nullglob
		((${#keys[@]} == 1)) || die "found ${#keys[@]} public keys in $USER_HOME/.ssh; choose one with --pubkey"
		PUBKEY=${keys[0]}
	fi
fi
[[ $PUBKEY == *.pub ]] || die "--pubkey must point to a .pub file (never a private key)"
[[ -f $PUBKEY ]] || die "public key not found: $PUBKEY"
KEY_FP=$(ssh-keygen -l -f "$PUBKEY") || die "not a valid SSH public key: $PUBKEY"
grep -q 'PRIVATE KEY' "$PUBKEY" && die "$PUBKEY looks like a private key"

gen_pw() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 20; }

if [[ -f $CRED_FILE ]]; then
	log "Reusing passwords from $CRED_FILE"
	ROOT_PW=$(sed -n 's/^root_password=//p' "$CRED_FILE")
	USER_PW=$(sed -n 's/^user_password=//p' "$CRED_FILE")
	[[ -n $ROOT_PW && -n $USER_PW ]] || die "$CRED_FILE exists but is incomplete; move it away"
else
	ROOT_PW=$(gen_pw)
	USER_PW=$(gen_pw)
	if ((DRY_RUN)); then
		printf '    [dry-run] write %s (mode 600) with new random passwords\n' "$CRED_FILE"
	else
		(
			umask 077
			cat >"$CRED_FILE" <<-EOF
			# NanoPi NEO2 credentials, generated $(date -Iseconds)
			hostname=$HOSTNAME_NEW
			root_password=$ROOT_PW
			user=$USERNAME
			user_password=$USER_PW
			EOF
		)
		chmod 600 "$CRED_FILE"
	fi
fi
ROOT_HASH=$(openssl passwd -6 "$ROOT_PW")
USER_HASH=$(openssl passwd -6 "$USER_PW")

# ---------------------------------------------------------------- step 2: device checks
[[ -b $DEVICE ]] || die "$DEVICE is not a block device"
DEVICE=$(readlink -f "$DEVICE")
[[ $(lsblk -dno TYPE "$DEVICE") == disk ]] || die "$DEVICE is not a whole disk (give /dev/sdX, not a partition)"
TRAN=$(lsblk -dno TRAN "$DEVICE" | tr -d ' ')
[[ $TRAN == usb ]] || die "$DEVICE is not a USB device (TRAN=${TRAN:-none}); refusing"
SIZE=$(lsblk -dbno SIZE "$DEVICE")
((SIZE > 0)) || die "$DEVICE reports size 0 (no card inserted?)"
((SIZE <= MAX_BYTES)) || die "$DEVICE is larger than 64 GB; refusing"

# Refuse if any system mount lives on this disk.
for mp in / /boot /boot/efi /home; do
	src=$(findmnt -no SOURCE "$mp" 2>/dev/null || true)
	[[ -b $src ]] || continue
	parent=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
	if [[ /dev/$parent == "$DEVICE" || $src == "$DEVICE" ]]; then
		die "$DEVICE holds $mp; refusing"
	fi
done

part_of() { # part_of DISK N -> partition device node
	if [[ $1 =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "${1}$2"; fi
}
ROOT_PART=$(part_of "$DEVICE" 1)

echo
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,VENDOR,FSTYPE,LABEL,MOUNTPOINTS "$DEVICE"
echo
cat <<-EOF
Plan:
  target device   : $DEVICE ($(numfmt --to=iec "$SIZE"), $(lsblk -dno MODEL "$DEVICE" | xargs))
  flash           : $( ((DO_FLASH)) && echo "yes, ALL DATA ON $DEVICE WILL BE DESTROYED" || echo "no (configure only)")
  image           : ${IMAGE:-download $IMAGE_URL}
  hostname        : $HOSTNAME_NEW
  user            : $USERNAME ($REALNAME), sudo
  ssh key         : $KEY_FP
  ssh password    : $([[ $PASSWORD_AUTH == yes ]] && echo enabled || echo "disabled (key-only)")
  root ssh        : prohibit-password (key only)
  timezone/locale : $TIMEZONE / $LOCALE
  credentials     : $CRED_FILE
EOF
echo

if ((!DRY_RUN)); then
	read -r -p "Type the device path ($DEVICE) to confirm: " answer
	[[ $answer == "$DEVICE" ]] || die "confirmation did not match; nothing written"
fi

cleanup() {
	if ((!DRY_RUN)) && mountpoint -q "$MNT" 2>/dev/null; then
		$SUDO umount "$MNT" || warn "could not unmount $MNT"
	fi
}
trap cleanup EXIT

unmount_device() {
	local p
	for p in $(lsblk -lnpo NAME "$DEVICE" | tail -n +2); do
		if findmnt -rno TARGET -S "$p" >/dev/null 2>&1; then
			run $SUDO umount "$p"
		fi
	done
}

log "Unmounting partitions on $DEVICE"
unmount_device

# ---------------------------------------------------------------- step 3: download + verify
if ((DO_FLASH)); then
	if [[ -z $IMAGE ]]; then
		log "Resolving $IMAGE_URL"
		if ((DRY_RUN)); then
			printf '    [dry-run] curl -fL %s (+ .sha, .asc) into %s\n' "$IMAGE_URL" "$CACHE_DIR"
			IMAGE="$CACHE_DIR/<resolved image>.img.xz"
		else
			final_url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$IMAGE_URL") \
				|| die "cannot resolve $IMAGE_URL"
			name=$(basename "${final_url%%\?*}")
			[[ $name == *.img.xz ]] || die "unexpected download name: $name"
			[[ $name == *_Nanopineo2_* || $name == *_nanopineo2_* ]] || warn "image name does not mention nanopineo2: $name"
			mkdir -p "$CACHE_DIR"
			IMAGE=$CACHE_DIR/$name
			SHA_FILE=$IMAGE.sha
			if [[ ! -f $IMAGE ]]; then
				curl -fL --retry 4 -o "$IMAGE.part" "$final_url" || die "download failed: $final_url"
				mv -f "$IMAGE.part" "$IMAGE"
			fi
			curl -fsSL --retry 4 -o "$SHA_FILE" "$final_url.sha" || die "no checksum file at $final_url.sha"
			curl -fsSL --retry 4 -o "$IMAGE.asc" "$final_url.asc" || warn "no signature file at $final_url.asc"
		fi
	fi

	if ((!DRY_RUN)); then
		[[ -f $IMAGE ]] || die "image not found: $IMAGE"
		[[ -z $SHA_FILE && -f $IMAGE.sha ]] && SHA_FILE=$IMAGE.sha
		[[ -n $SHA_FILE && -f $SHA_FILE ]] || die "no checksum file for $IMAGE (use --sha)"
		log "Verifying SHA-256"
		expected=$(grep -oE '^[0-9a-fA-F]{64}' "$SHA_FILE" | head -1)
		[[ -n $expected ]] || die "no SHA-256 found in $SHA_FILE"
		IMAGE_SHA=$(sha256sum "$IMAGE" | cut -d' ' -f1)
		[[ ${IMAGE_SHA,,} == "${expected,,}" ]] || die "checksum mismatch for $IMAGE"
		echo "    OK $IMAGE_SHA"

		if [[ -f $IMAGE.asc ]] && command -v gpg >/dev/null; then
			log "Checking GPG signature"
			gnupg_home=$(mktemp -d)
			if curl -fsSL "$ARMBIAN_KEY_URL" | gpg --homedir "$gnupg_home" --quiet --import 2>/dev/null \
				&& gpg --homedir "$gnupg_home" --verify "$IMAGE.asc" "$IMAGE" 2>&1 | tee "$gnupg_home/out" | grep -q 'Good signature'; then
				sed -n 's/.*using .* key /    signed by key /p' "$gnupg_home/out"
			elif grep -q 'BAD signature' "$gnupg_home/out" 2>/dev/null; then
				rm -rf "$gnupg_home"
				die "BAD GPG signature on $IMAGE"
			else
				warn "GPG signature could not be checked (key not available); relying on SHA-256"
			fi
			rm -rf "$gnupg_home"
		fi
	fi

# ---------------------------------------------------------------- step 4: flash
	log "Wiping signatures and writing image to $DEVICE"
	run $SUDO wipefs -a "$DEVICE"
	if ((DRY_RUN)); then
		printf '    [dry-run] xz -dc %s | sudo dd of=%s bs=4M conv=fsync status=progress\n' "$IMAGE" "$DEVICE"
	elif [[ $IMAGE == *.xz ]]; then
		xz -dc "$IMAGE" | $SUDO dd of="$DEVICE" bs=4M conv=fsync status=progress
	else
		$SUDO dd if="$IMAGE" of="$DEVICE" bs=4M conv=fsync status=progress
	fi
	run sync

	if ((VERIFY_WRITE && !DRY_RUN)); then
		log "Reading back and comparing"
		if [[ $IMAGE == *.xz ]]; then
			img_bytes=$(xz --robot -l "$IMAGE" | awk '$1=="totals"{print $5}')
			src_sha=$(xz -dc "$IMAGE" | sha256sum | cut -d' ' -f1)
		else
			img_bytes=$(stat -c %s "$IMAGE")
			src_sha=$(sha256sum "$IMAGE" | cut -d' ' -f1)
		fi
		dev_sha=$($SUDO head -c "$img_bytes" "$DEVICE" | sha256sum | cut -d' ' -f1)
		[[ $src_sha == "$dev_sha" ]] || die "read-back mismatch: card $dev_sha != image $src_sha"
		echo "    OK $dev_sha"
	fi

	run $SUDO partprobe "$DEVICE"
	((DRY_RUN)) || udevadm settle 2>/dev/null || sleep 2
	unmount_device   # desktop auto-mounters may grab the new partition
fi

# ---------------------------------------------------------------- step 5: configure
if ((!DRY_RUN)); then
	[[ -b $ROOT_PART ]] || die "$ROOT_PART not found after flashing"
	fstype=$($SUDO blkid -s TYPE -o value "$ROOT_PART")
	[[ $fstype == ext4 ]] || die "$ROOT_PART is $fstype, expected the Armbian ext4 rootfs"
fi

log "Mounting $ROOT_PART on $MNT"
run $SUDO mkdir -p "$MNT"
run $SUDO mount "$ROOT_PART" "$MNT"
if ((!DRY_RUN)); then
	[[ -f $MNT/etc/armbian-release ]] || die "$ROOT_PART does not look like an Armbian rootfs"
	# shellcheck disable=SC1091
	IMAGE_INFO=$(. "$MNT/etc/armbian-release"; echo "Armbian ${VERSION:-?} ${DISTRIBUTION_CODENAME:-?} board=${BOARD:-?} kernel=${BRANCH:-?}")
	echo "    $IMAGE_INFO"
	grep -q "^BOARD=${BOARD}\$" "$MNT/etc/armbian-release" || warn "image is not built for BOARD=$BOARD"
fi

log "Root SSH key"
run $SUDO install -d -m 700 -o 0 -g 0 "$MNT/root/.ssh"
run $SUDO install -m 600 -o 0 -g 0 "$PUBKEY" "$MNT/root/.ssh/authorized_keys"

log "Hostname: $HOSTNAME_NEW"
echo "$HOSTNAME_NEW" | put_file "$MNT/etc/hostname" 644
if ((!DRY_RUN)); then
	if grep -q '^127\.0\.1\.1' "$MNT/etc/hosts"; then
		$SUDO sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME_NEW/" "$MNT/etc/hosts"
	else
		printf '127.0.1.1\t%s\n' "$HOSTNAME_NEW" | $SUDO tee -a "$MNT/etc/hosts" >/dev/null
	fi
else
	printf '    [dry-run] set 127.0.1.1 %s in /etc/hosts\n' "$HOSTNAME_NEW"
fi

log "Timezone: $TIMEZONE"
if ((!DRY_RUN)); then
	[[ -f $MNT/usr/share/zoneinfo/$TIMEZONE ]] || die "unknown timezone in image: $TIMEZONE"
fi
run $SUDO ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$MNT/etc/localtime"
echo "$TIMEZONE" | put_file "$MNT/etc/timezone" 644

log "SSH daemon settings"
{
	echo "# written by flash-neo2.sh"
	echo "PermitRootLogin prohibit-password"
	echo "PubkeyAuthentication yes"
	if [[ $PASSWORD_AUTH == no ]]; then
		echo "PasswordAuthentication no"
		echo "KbdInteractiveAuthentication no"
	fi
} | put_file "$MNT/etc/ssh/sshd_config.d/10-neo2.conf" 644
if ((!DRY_RUN)); then
	# Debian's sshd_config includes sshd_config.d/ at the top, and the first
	# value wins, so the drop-in beats Armbian's "PermitRootLogin yes".
	if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MNT/etc/ssh/sshd_config"; then
		warn "sshd_config has no Include for sshd_config.d; editing it directly"
		$SUDO sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' "$MNT/etc/ssh/sshd_config"
		if [[ $PASSWORD_AUTH == no ]]; then
			$SUDO sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' "$MNT/etc/ssh/sshd_config"
		fi
	fi
fi

# Armbian first-login presets. Armbian runs armbian-firstlogin on the first
# interactive root login (the autologin on the serial console at first boot,
# or the first ssh session) and reads /root/.not_logged_in_yet as presets.
# Variable names change between releases, so check them in this image.
FIRSTLOGIN=$MNT/usr/lib/armbian/armbian-firstlogin
PRESET_OK=0
NET_VAR=""
if ((DRY_RUN)); then
	printf '    [dry-run] check preset variable names in %s\n' "${FIRSTLOGIN#"$MNT"}"
	PRESET_OK=1
	NET_VAR=PRESET_NET_CHANGE_DEFAULTS
elif [[ -f $FIRSTLOGIN ]]; then
	PRESET_OK=1
	for v in PRESET_ROOT_PASSWORD PRESET_USER_NAME PRESET_USER_PASSWORD PRESET_DEFAULT_REALNAME \
		PRESET_USER_SHELL PRESET_TIMEZONE PRESET_LOCALE SET_LANG_BASED_ON_LOCATION; do
		grep -q "\b$v\b" "$FIRSTLOGIN" || { warn "armbian-firstlogin does not know $v"; PRESET_OK=0; }
	done
	for v in PRESET_NET_CHANGE_DEFAULTS FR_net_change_defaults; do
		grep -q "\b$v\b" "$FIRSTLOGIN" && { NET_VAR=$v; break; }
	done
else
	warn "armbian-firstlogin not found in image"
fi

if ((PRESET_OK)); then
	log "Writing first-login presets"
	{
		echo "# Armbian first-login presets, written by flash-neo2.sh"
		[[ -n $NET_VAR ]] && echo "$NET_VAR=0"
		echo "PRESET_ROOT_PASSWORD=\"$ROOT_PW\""
		echo "PRESET_USER_NAME=\"$USERNAME\""
		echo "PRESET_USER_PASSWORD=\"$USER_PW\""
		echo "PRESET_DEFAULT_REALNAME=\"$REALNAME\""
		echo "PRESET_USER_SHELL=\"bash\""
		echo "PRESET_TIMEZONE=\"$TIMEZONE\""
		echo "PRESET_LOCALE=\"$LOCALE\""
		echo "SET_LANG_BASED_ON_LOCATION=\"n\""
	} | put_file "$MNT/root/.not_logged_in_yet" 600
else
	warn "presets not supported by this image; the one-shot unit will create $USERNAME and skip the wizard"
fi

# One-shot unit: makes sure the user exists, then copies root's key to it.
# Waits for armbian-firstlogin (if it runs), else creates the user itself.
log "Installing one-shot user/key unit"
put_file "$MNT/root/.neo2-firstboot.conf" 600 <<EOF
NEO2_USER='$USERNAME'
NEO2_REALNAME='$REALNAME'
NEO2_USER_HASH='$USER_HASH'
NEO2_ROOT_HASH='$ROOT_HASH'
NEO2_PRESET_OK=$PRESET_OK
EOF

put_file "$MNT/usr/local/sbin/neo2-firstboot-user" 755 <<'EOF'
#!/bin/bash
# Installed by flash-neo2.sh. Runs once, then removes itself.
set -u
conf=/root/.neo2-firstboot.conf
[[ -f $conf ]] || exit 0
. "$conf"

# Give armbian-firstlogin (serial console autologin) up to 10 minutes.
for _ in $(seq 120); do
	id "$NEO2_USER" >/dev/null 2>&1 && [[ ! -f /root/.not_logged_in_yet ]] && break
	[[ $NEO2_PRESET_OK == 0 ]] && break
	sleep 5
done

if ! id "$NEO2_USER" >/dev/null 2>&1; then
	echo "creating $NEO2_USER (armbian-firstlogin did not run)"
	useradd --create-home --shell /bin/bash --comment "$NEO2_REALNAME" --user-group "$NEO2_USER" || exit 1
	for g in sudo adm systemd-journal dialout video audio plugdev netdev i2c gpio spi ssh; do
		getent group "$g" >/dev/null && usermod -aG "$g" "$NEO2_USER"
	done
	usermod -p "$NEO2_USER_HASH" "$NEO2_USER"
	usermod -p "$NEO2_ROOT_HASH" root
	# without presets the wizard would prompt interactively; it is done now
	[[ $NEO2_PRESET_OK == 0 ]] && rm -f /root/.not_logged_in_yet
fi

home=$(getent passwd "$NEO2_USER" | cut -d: -f6)
group=$(id -gn "$NEO2_USER")
install -d -m 700 -o "$NEO2_USER" -g "$group" "$home/.ssh"
if [[ -s /root/.ssh/authorized_keys ]]; then
	touch "$home/.ssh/authorized_keys"
	while IFS= read -r line; do
		grep -qxF "$line" "$home/.ssh/authorized_keys" || echo "$line" >>"$home/.ssh/authorized_keys"
	done </root/.ssh/authorized_keys
	chown "$NEO2_USER:$group" "$home/.ssh/authorized_keys"
	chmod 600 "$home/.ssh/authorized_keys"
fi

rm -f "$conf"
systemctl disable neo2-firstboot-user.service
rm -f /etc/systemd/system/neo2-firstboot-user.service /usr/local/sbin/neo2-firstboot-user
echo "done: $NEO2_USER has root's authorized_keys"
EOF

put_file "$MNT/etc/systemd/system/neo2-firstboot-user.service" 644 <<'EOF'
[Unit]
Description=Create first user and copy root SSH key (flash-neo2.sh)
After=multi-user.target
ConditionPathExists=/root/.neo2-firstboot.conf

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/neo2-firstboot-user
TimeoutStartSec=15min

[Install]
WantedBy=multi-user.target
EOF
run $SUDO mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
run $SUDO ln -sfn /etc/systemd/system/neo2-firstboot-user.service \
	"$MNT/etc/systemd/system/multi-user.target.wants/neo2-firstboot-user.service"

run sync
run $SUDO umount "$MNT"

# ---------------------------------------------------------------- step 6: verify read-only
log "Verifying (read-only mount)"
run $SUDO mount -o ro "$ROOT_PART" "$MNT"
if ((!DRY_RUN)); then
	fail=0
	check() { if eval "$2"; then printf '    ok   %s\n' "$1"; else printf '    FAIL %s\n' "$1"; fail=1; fi; }
	ak=$MNT/root/.ssh/authorized_keys
	check "root .ssh 700 root:root"          "[[ \$($SUDO stat -c '%a %u:%g' $MNT/root/.ssh) == '700 0:0' ]]"
	check "root authorized_keys 600 root:root" "[[ \$($SUDO stat -c '%a %u:%g' $ak) == '600 0:0' ]]"
	check "authorized_keys matches $PUBKEY"  "$SUDO cmp -s $ak '$PUBKEY'"
	check "hostname = $HOSTNAME_NEW"         "[[ \$(cat $MNT/etc/hostname) == '$HOSTNAME_NEW' ]]"
	check "hosts has 127.0.1.1 $HOSTNAME_NEW" "grep -qP '^127\.0\.1\.1\t$HOSTNAME_NEW\$' $MNT/etc/hosts"
	check "localtime -> $TIMEZONE"           "[[ \$(readlink $MNT/etc/localtime) == */$TIMEZONE ]]"
	check "sshd drop-in present"             "grep -q 'PermitRootLogin prohibit-password' $MNT/etc/ssh/sshd_config.d/10-neo2.conf"
	check "one-shot unit enabled"            "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/neo2-firstboot-user.service ]]"
	check "one-shot config 600"              "[[ \$($SUDO stat -c '%a' $MNT/root/.neo2-firstboot.conf) == 600 ]]"
	if ((PRESET_OK)); then
		check "preset file 600"              "[[ \$($SUDO stat -c '%a' $MNT/root/.not_logged_in_yet) == 600 ]]"
		echo "    preset file (passwords masked):"
		$SUDO sed -E 's/(PASSWORD=).*/\1"********"/; s/^/      /' "$MNT/root/.not_logged_in_yet"
	fi
fi
run $SUDO umount "$MNT"
run sync
((DRY_RUN)) || ((fail == 0)) || die "verification failed; see FAIL lines above"

# ---------------------------------------------------------------- hand-off
echo
if ((DRY_RUN)); then
	log "Dry run complete; nothing was changed."
	exit 0
fi
log "Done. The card is safe to remove."
cat <<-EOF

  OS          : ${IMAGE_INFO:-Armbian}
  image       : ${IMAGE:-(not flashed, configure only)}
  sha256      : ${IMAGE_SHA:-n/a}
  hostname    : $HOSTNAME_NEW
  user        : $USERNAME (sudo), same SSH key as root
  credentials : $(readlink -f "$CRED_FILE")

  First boot: 1-3 min (the rootfs is resized to fill the card).
  Find the IP: your router's DHCP leases, 'ping $HOSTNAME_NEW.local' (if
  mDNS is available), or 'nmap -sn <your-lan>/24'.
  Log in:      ssh root@<ip>    or    ssh $USERNAME@<ip>
  The user and its key are ready about 1 minute after the first boot finishes.
EOF
