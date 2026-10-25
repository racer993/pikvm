# NanoPi NEO2: headless Armbian microSD

`flash-neo2.sh` writes Armbian Debian 13 "trixie" Minimal (mainline kernel) to a
microSD card and pre-configures it so the first boot needs no monitor, keyboard
or serial console.

Linux only (the rootfs is ext4). Run as a normal user with sudo rights.

## Usage

```bash
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL      # find the card, e.g. /dev/sdb
./flash-neo2.sh --device /dev/sdb --dry-run   # print the plan, change nothing
./flash-neo2.sh --device /dev/sdb             # download, verify, flash, configure
```

Useful options (`--help` lists all):

| Option | Default |
|---|---|
| `--hostname NAME` | `neo2` |
| `--user NAME` | `rolf` |
| `--pubkey FILE` | `~/.ssh/id_ed25519.pub`, else the only `~/.ssh/*.pub` |
| `--password-auth` / `--no-password-auth` | key-only |
| `--image FILE --sha FILE` | download `https://dl.armbian.com/nanopineo2/Trixie_current_minimal` |
| `--no-flash` | re-configure an already flashed card |
| `--verify-write` | read the card back and compare hashes |

## What it does

1. Picks your SSH **public** key, then generates random root and user passwords
   into `./neo2-credentials.txt` (mode 600). A re-run reuses that file.
2. Refuses any device that is not a whole USB disk, is over 64 GB, or holds
   `/`, `/boot` or `/home`. It shows `lsblk` and makes you type the device path.
3. Downloads the image with its `.sha` and `.asc` files, checks SHA-256, and checks
   the GPG signature when `gpg` is available.
4. Runs `wipefs` on the card, then `xz -dc | dd` to write the image.
5. Mounts the ext4 rootfs and configures:
   - `/root/.ssh/authorized_keys` (700/600)
   - hostname and `/etc/hosts`
   - timezone Europe/Berlin
   - `sshd_config.d/10-neo2.conf`: `PermitRootLogin prohibit-password`, and
     `PasswordAuthentication no` unless you pass `--password-auth`
   - `/root/.not_logged_in_yet`: Armbian first-login presets for root and user
     passwords, user, real name, shell, timezone and locale. The script first
     checks the variable names against this image's `armbian-firstlogin`.
   - a one-shot unit `neo2-firstboot-user.service`. It waits up to 10 minutes
     for the Armbian first-login to create the user. If that hasn't happened,
     it creates the user itself (password from a SHA-512 hash). Then it copies
     root's `authorized_keys` to the user and removes itself.
6. Re-mounts the rootfs read-only, checks owners, modes and contents, and
   unmounts the card.

Armbian runs its first-login on the first interactive root login. At first boot
that is the automatic root login on the serial console, so the presets apply
without anyone connecting. If they don't, the first `ssh root@<ip>` applies them.

## After flashing

- First boot takes 1–3 minutes while the rootfs is resized to fill the card.
- Find the IP in your router's DHCP leases, with `ping neo2.local` (if mDNS is
  available), or with `nmap -sn 192.168.x.0/24`.
- Log in with `ssh root@<ip>` or `ssh rolf@<ip>`.
- Serial console: 3.3 V USB-TTL cable on the 4-pin debug header (GND, TX↔RX,
  RX↔TX, leave 5 V free), 115200 8N1.
