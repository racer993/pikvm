# NanoPi NEO2 provisioning: handover

Branch: `claude/brave-sagan-d1xj5o` (repo `racer993/pikvm`), all work under `neo2/`.
Previous session: https://claude.ai/code/session_011hzbkYb12rkeWPiHZ3m6j4

The earlier work ran in a cloud container with no access to the laptop's USB ports,
the SD cards or `~/.ssh`. Nothing has been flashed yet. Everything below needs to
run on the laptop.

```bash
git fetch origin claude/brave-sagan-d1xj5o
git checkout claude/brave-sagan-d1xj5o
cd neo2
```

## Goal

Two headless, SSH-ready microSD cards for a FriendlyELEC NanoPi NEO2 (512 MB,
Allwinner H5, arm64, Gigabit Ethernet, boots from microSD only). Each card is a
16 GB microSD in a USB adapter. All data on the cards may be destroyed.

- Card 1: **Armbian Debian 13 "trixie" Minimal** (the user's choice, option 1)
- Card 2: **Plain Debian 13** (debootstrap/mmdebstrap + Debian's U-Boot and kernel, option 4)

## Decisions already made

| Setting | Value |
|---|---|
| Hostname | `neo2` |
| Regular user | `rolf` (sudo) |
| SSH key | `~/.ssh/id_ed25519.pub`, else the only `~/.ssh/*.pub`; installed for root **and** rolf |
| SSH password auth | **disabled** (key-only); root login `prohibit-password` |
| Passwords | random, stored mode 600 in `./neo2-credentials.txt` (Armbian) or `./neo2-debian-credentials.txt` (Debian) |
| Timezone / locale | Europe/Berlin / en_US.UTF-8 |
| Device safety | whole disk, `TRAN=usb`, ≤ 64 GB, does not hold `/`, `/boot` or `/home`; the user must type the device path to confirm |

## Files

| File | Status |
|---|---|
| `flash-neo2.sh` + `README.md` | **Done.** Armbian: download → SHA-256/GPG check → wipefs + dd → presets → read-only verify. `--dry-run`, `--no-flash`, `--verify-write`. |
| `debian/build-debian-neo2.sh` + `debian/README.md` | **Done, not yet tested against Debian** (see below). Builds the image with mmdebstrap, writes it to the card or an image file, and checks itself before finishing. |
| `usb-wifi-detect.sh` | **Done.** Watches USB ports and reports USB ID, driver and firmware for each newly plugged device. |
| `.gitignore` | Ignores images, credential files and `usb-wifi-report.txt`. |

Serial wiring guide (web page): https://claude.ai/artifact/K9cA2mRtwzU3PRCopAxoMo

## Next steps (in order)

1. **Flash card 1 (Armbian):**
   ```bash
   lsblk -o NAME,SIZE,TYPE,TRAN,MODEL
   ./flash-neo2.sh --device /dev/sdX --dry-run
   ./flash-neo2.sh --device /dev/sdX
   ```
   If the download step fails, download the image and its `.sha` file from the
   Armbian board page yourself, then pass `--image FILE --sha FILE.sha`.
2. **Boot it**, with Ethernet and the serial cable connected (see below). First boot
   takes 1–3 minutes because the rootfs is resized. Then run `ssh root@neo2.local`
   or `ssh rolf@<ip>`.
3. **Identify the two USB WLAN adapters:** `sudo ./usb-wifi-detect.sh`. Plug them in
   one at a time, then press Ctrl-C. The output goes to `usb-wifi-report.txt`.
4. **Add the WLAN drivers to both images** (not done yet):
   - Debian builder: add the `non-free-firmware` component, the right firmware
     package (`firmware-realtek`, `firmware-mediatek`, `firmware-atheros` or
     `firmware-misc-nonfree`), `wireless-regdb`, `iw` and `wpasupplicant` to the package list.
   - Armbian: let `flash-neo2.sh` install those packages on first boot (or after
     login), or check whether `armbian-firmware` already covers the chip.
   - Some Realtek chips have no mainline driver (some RTL8812AU/8814AU/8821AU
     adapters). They need a DKMS module and kernel headers. Check the chip first.
5. **Build card 2 (plain Debian):**
   ```bash
   cd debian
   sudo ./build-debian-neo2.sh --device /dev/sdX --dry-run
   sudo ./build-debian-neo2.sh --device /dev/sdX
   ```
   Watch the first boot on the serial console.
6. Optional: add compressed RAM swap (`zram-tools`) to the Debian image. The board
   has 512 MB of RAM and no swap. Suggested but not confirmed by the user.

## Known caveats

**Armbian (`flash-neo2.sh`)**
- Download URL `https://dl.armbian.com/nanopineo2/Trixie_current_minimal` (+ `.sha`,
  `.asc`) was not reachable from the cloud container, so the download step is untested.
- The first-login preset names come from current `armbian/build` main
  (`PRESET_NET_CHANGE_DEFAULTS`, not `FR_net_change_defaults`). The script checks
  them against `armbian-firstlogin` inside the image before writing.
- `armbian-firstlogin` only runs on an interactive login. At first boot that is the
  automatic root login on the serial console. As a fallback, the one-shot unit
  `neo2-firstboot-user.service` creates `rolf` if it still doesn't exist after
  10 minutes, then copies root's `authorized_keys` and removes itself.
- Tested against a fake rootfs (all verify checks pass, re-runs work). Not
  tested on real hardware.

**Plain Debian (`debian/build-debian-neo2.sh`)**
- Debian mirrors were blocked in the cloud, so the full test build ran against
  **Ubuntu noble arm64**. The `NEO2_*` environment overrides used for that are test-only.
  The test build passed, and the image was inspected (U-Boot at 8 KiB, extlinux,
  PARTUUID, key modes, services).
- Not checked against Debian trixie: the DTB path
  `/usr/lib/linux-image-<ver>/allwinner/sun50i-h5-nanopi-neo2.dtb`, and the names
  `systemd-resolved`, `systemd-timesyncd`, `cloud-guest-utils`, `fake-hwclock`,
  `libnss-mdns`, `openssh-sftp-server`, `zstd` and `fdisk`. The built-in check
  aborts the build if any of these is wrong.
- The debootstrap fallback path has not been run.

## Serial console (3.3 V USB-TTL cable)

- Use the **3.3 V** cable. The H5 is not 5 V tolerant.
- Use the separate **4-pin debug header (UART0)**, next to the small audio header
  beside the USB-A port. It may need pins soldered in. UART0 is not on the 24-pin header.
- Pin 1 is furthest from the board edge. To confirm, pin 1 should beep against the
  metal shell of the Ethernet or USB jack (multimeter continuity mode).

| Pin | Signal | Wire |
|---|---|---|
| 1 | GND | black |
| 2 | 5V | red: **leave unconnected** (power the board via micro-USB) |
| 3 | TX (board out) | white (cable RX) |
| 4 | RX (board in) | green (cable TX) |

- Settings: 115200 8N1, no flow control: `picocom -b 115200 /dev/ttyUSB0`.
- Wire colours vary by cable. With only the cable plugged into the PC, green to
  black should read about 3.3 V.
- Pin order is confirmed by the FriendlyELEC pin table and the linux-sunxi wiki.
  No board photo was checked.
