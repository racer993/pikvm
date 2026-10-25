#!/usr/bin/env bash
# usb-wifi-detect.sh - watch this machine's USB ports and report every newly
# plugged device: USB ID, product name, kernel driver, wireless interface and
# the firmware files the driver loaded. Plug the WLAN adapters in one at a
# time while it runs, then press Ctrl-C. The report is saved to
# ./usb-wifi-report.txt so the drivers can be added to the NEO2 images.
#
#   ./usb-wifi-detect.sh            # no root needed; root adds firmware lines

set -euo pipefail

REPORT=./usb-wifi-report.txt
INTERVAL=2

[[ $(uname -s) == Linux ]] || { echo "Linux only" >&2; exit 1; }

# One line per USB device: sysfs path
list_devices() {
	local d
	for d in /sys/bus/usb/devices/*; do
		[[ -f $d/idVendor ]] && echo "${d##*/}"
	done | sort
}

describe() {
	local dev=$1 sys=/sys/bus/usb/devices/$1 vid pid product maker drivers ifaces iface fw
	vid=$(<"$sys/idVendor")
	pid=$(<"$sys/idProduct")
	product=$(cat "$sys/product" 2>/dev/null || echo "?")
	maker=$(cat "$sys/manufacturer" 2>/dev/null || echo "?")

	# drivers bound to the device's interfaces (e.g. rtw88_8822bu, mt76x2u)
	drivers=$(for i in "$sys"/"$dev":*; do
		[[ -L $i/driver ]] && basename "$(readlink "$i/driver")"
	done | sort -u | xargs)

	# network interfaces created by this device
	ifaces=$(for n in "$sys"/"$dev":*/net/*; do
		[[ -e $n ]] && basename "$n"
	done | xargs)

	echo "------------------------------------------------------------"
	echo "time      : $(date '+%F %T')"
	echo "usb id    : $vid:$pid"
	echo "product   : $maker / $product"
	echo "usb speed : $(cat "$sys/speed" 2>/dev/null || echo "?") Mbit/s"
	echo "driver    : ${drivers:-none bound (driver missing on this machine?)}"
	echo "interface : ${ifaces:-none}"
	for iface in $ifaces; do
		if [[ -d /sys/class/net/$iface/wireless || -d /sys/class/net/$iface/phy80211 ]]; then
			echo "wireless  : yes ($iface, $(basename "$(readlink -f /sys/class/net/"$iface"/phy80211)"))"
		fi
	done
	for d in $drivers; do
		echo "module    : $d ($(modinfo -F filename "$d" 2>/dev/null || echo "not a module / unknown"))"
	done
	# firmware the kernel loaded in the last minute (needs root for dmesg on most distros)
	fw=$(dmesg 2>/dev/null | tail -n 200 | grep -iE 'firmware|fw' | grep -iE "$(echo "$drivers" | tr ' ' '|')|$vid|rtw|rtl|mt7|ath|carl" | tail -n 5 || true)
	[[ -n $fw ]] && echo "firmware  :" && sed 's/^/    /' <<<"$fw"
	if [[ -z $drivers ]]; then
		echo "modalias  : $(cat "$sys"/"$dev":1.0/modalias 2>/dev/null || echo "?")"
	fi
}

echo "Watching USB ports (every ${INTERVAL}s). Plug in the WLAN adapters one at a time; Ctrl-C to finish."
echo "Already connected devices are ignored."
: >"$REPORT"
known=$(list_devices)
trap 'echo; echo "Report saved to $REPORT"; exit 0' INT

while sleep "$INTERVAL"; do
	now=$(list_devices)
	added=$(comm -13 <(echo "$known") <(echo "$now"))
	removed=$(comm -23 <(echo "$known") <(echo "$now"))
	for dev in $removed; do
		echo "removed: $dev"
	done
	for dev in $added; do
		sleep 3   # give the driver time to bind and load firmware
		[[ -d /sys/bus/usb/devices/$dev ]] || continue
		describe "$dev" | tee -a "$REPORT"
	done
	known=$now
done
