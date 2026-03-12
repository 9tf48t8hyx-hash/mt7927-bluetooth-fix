# MT7927 WiFi & Bluetooth Fix for Linux

Fix **WiFi and Bluetooth** on motherboards using the **MediaTek Filogic 380 (MT7927)** combo chip, where neither WiFi (PCIe, chip ID `14c3:6639`) nor Bluetooth (USB, e.g. `13d3:3588`) are recognized by the upstream Linux kernel.

## The Problem

Many recent AMD AM5 motherboards ship with the MediaTek MT7927 wireless chip. The upstream kernel's `mt7925e` WiFi driver and `btusb`/`btmtk` Bluetooth drivers do not support the MT7927 variant:

**WiFi** — The PCIe device `14c3:6639` is not in the `mt7925e` driver's PCI ID table. No wireless interface is created. `lspci` shows the device but no driver is bound.

**Bluetooth** — The USB device (e.g. `13d3:3588`) is caught by a generic `btusb` match, but the `BTUSB_MEDIATEK` quirk is missing, so firmware is never loaded. This produces:
```
Bluetooth: hci0: Opcode 0x0c03 failed: -16
```

**Firmware** — The MT6639 WiFi and Bluetooth firmware files are not included in the `linux-firmware` package.

## Affected Hardware

**Motherboards** (non-exhaustive):
- ASUS ROG Strix X870-I Gaming WiFi
- ASUS ROG Crosshair X870E Hero
- ASUS ROG Strix X870E-E Gaming WiFi
- ASUS ROG Strix B850-I Gaming WiFi
- ASUS ProArt X870E-Creator WiFi
- Other AM5 boards with MediaTek MT7925/MT7927 wireless

**Important:** These boards require the **external WiFi/BT antenna** screwed into the SMA connectors on the rear I/O panel. Without it, WiFi range is severely limited and Bluetooth is effectively non-functional.

**Device IDs:**

| Bus | ID | Description |
|-----|----|-------------|
| PCIe | `14c3:6639` | MT7927 WiFi |
| USB | `13d3:3588` | MT6639 Bluetooth (IMC Networks / ASUS) |
| USB | `0489:e13a` | MT6639 Bluetooth (Foxconn) |
| USB | `0489:e0fa` | MT6639 Bluetooth (Foxconn) |
| USB | `0489:e10f` | MT6639 Bluetooth (Foxconn) |
| USB | `0489:e110` | MT6639 Bluetooth (Foxconn) |
| USB | `0489:e116` | MT6639 Bluetooth (Foxconn) |

Check your devices:
```bash
lspci -nn | grep -i network
lsusb | grep -iE "bluetooth|wireless"
```

**Tested on:**
- Fedora 43 (KDE Plasma), kernel 6.19.6, ASUS ROG Strix X870-I Gaming WiFi
- Should work on Fedora 41+, kernel 6.12+

## Quick Install

```bash
git clone https://github.com/9tf48t8hyx-hash/mt7927-bluetooth-fix.git
cd mt7927-bluetooth-fix
sudo ./install.sh
```

The script handles everything:
1. Installs build dependencies (`gcc`, `kernel-devel`, `dkms`)
2. Downloads the matching kernel source
3. Extracts and patches the `mt76` WiFi driver and `btusb`/`btmtk` Bluetooth drivers
4. Builds and installs all modules via DKMS (survives kernel updates)
5. Downloads and installs MT6639 WiFi + BT firmware from the official ASUS driver package
6. Loads the drivers and activates WiFi and Bluetooth

After installation, a **reboot** is recommended for clean module loading.

## After a Kernel Update

DKMS automatically rebuilds the modules when a new kernel is installed. If for some reason it doesn't work, re-run:

```bash
cd mt7927-bluetooth-fix
sudo ./install.sh
```

## Uninstall

```bash
sudo ./uninstall.sh
```

This removes the DKMS modules and firmware, restoring upstream drivers.

## How It Works

### WiFi — mt76/mt7925e patches (18 patches)

The `mt7925e` driver is patched to recognize the MT7927 chip ID (`0x6639` via PCIe) and load the correct firmware. Key changes:
- Chip ID helpers to identify MT7927 hardware
- Firmware paths and PCI ID registration for `14c3:6639`
- CBTOP remap and chip initialization sequence
- DMA ring, IRQ, and prefetch configuration
- MCU initialization adjustments
- Power management, DBDC, and CNM fixes
- 320 MHz (WiFi 7) EHT capabilities support
- ASPM disabled for stability

### Bluetooth — btusb/btmtk patch

- Adds MT7927 USB IDs to `btusb` `quirks_table` with `BTUSB_MEDIATEK` flag
- Adds MT6639 chip ID (`0x6639`) to `btmtk` firmware loading logic
- Firmware section filtering (skips WiFi sections during BT firmware download)
- Firmware persistence detection across soft resets

### Firmware

Extracted from the official MediaTek Windows driver package (distributed by ASUS):
- `BT_RAM_CODE_MT6639_2_1_hdr.bin` → `/lib/firmware/mediatek/mt6639/`
- `WIFI_MT6639_PATCH_MCU_2_1_hdr.bin` → `/lib/firmware/mediatek/mt7927/`
- `WIFI_RAM_CODE_MT6639_2_1.bin` → `/lib/firmware/mediatek/mt7927/`

## Troubleshooting

**WiFi interface not appearing after install**
```bash
sudo modprobe mt7925e
dmesg | grep mt7925
```
If you see firmware errors, check that `/lib/firmware/mediatek/mt7927/` contains the firmware files.

**Bluetooth: "No default controller available"**
```bash
dmesg | grep -i bluetooth
```
The MT6639 firmware download takes ~15 seconds. Wait for "Device setup" in dmesg. Then:
```bash
sudo rfkill unblock bluetooth
bluetoothctl power on
```

**After reboot, Bluetooth is off**
Ensure `AutoEnable=true` in `/etc/bluetooth/main.conf` (set automatically by the installer).

**WiFi connected but slow**
Make sure the external antenna is properly screwed in on both SMA connectors.

## Credits

This project is based on the excellent work of [jetm/mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms), which provides the kernel patches and firmware extraction tools. This repository repackages it as a simpler one-command installer focused on Fedora.

## Upstream Status

As of March 2026, MT7927/MT6639 support has **not** been merged into the mainline Linux kernel. Once merged, this fix will no longer be necessary.

## License

Install/uninstall scripts and documentation: MIT License.

Kernel patches, DKMS configuration, and firmware tools: derived from [mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms) and the Linux kernel, both GPL-2.0.
