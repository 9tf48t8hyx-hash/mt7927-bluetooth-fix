# MT7927 Bluetooth Fix for Linux

Fix Bluetooth on motherboards using the **MediaTek Filogic 380 (MT7927)** combo WiFi/BT chip, where the Bluetooth controller (MT6639) is not recognized by the upstream Linux kernel.

## The Problem

Many recent AMD AM5 motherboards ship with the MediaTek MT7927 wireless chip. While WiFi typically works out of the box (the MT7925 PCIe driver handles it), **Bluetooth does not**. The BT side uses an internal MT6639 controller connected via USB, but:

1. The USB device ID (e.g. `13d3:3588`) is missing from the kernel's `btusb` quirks table
2. The `btmtk` driver does not know how to handle the MT6639 chip ID (`0x6639`)
3. The MT6639 Bluetooth firmware is not included in the `linux-firmware` package

This results in the infamous error in `dmesg`:
```
Bluetooth: hci0: Opcode 0x0c03 failed: -16
```
And `bluetoothctl show` reports "No default controller available".

## Affected Hardware

**Motherboards** (non-exhaustive):
- ASUS ROG Strix X870-I Gaming WiFi
- ASUS ROG Crosshair X870E Hero
- ASUS ROG Strix X870E-E Gaming WiFi
- ASUS ROG Strix B850-I Gaming WiFi
- ASUS ProArt X870E-Creator WiFi
- Other AM5 boards with MediaTek MT7925/MT7927 wireless

**USB Device IDs** handled by this fix:
| USB ID | Vendor | Notes |
|--------|--------|-------|
| `13d3:3588` | IMC Networks (ASUS) | Most common |
| `0489:e13a` | Foxconn | |
| `0489:e0fa` | Foxconn | |
| `0489:e10f` | Foxconn | |
| `0489:e110` | Foxconn | |
| `0489:e116` | Foxconn | |

Check your device with:
```bash
lsusb | grep -iE "bluetooth|wireless"
```

**Tested on:**
- Fedora 43 (KDE Plasma), kernel 6.19.6
- Should work on Fedora 41+, kernel 6.12+ (may need patch adjustments for older kernels)

## Quick Install

```bash
git clone https://github.com/9tf48t8hyx-hash/mt7927-bluetooth-fix.git
cd mt7927-bluetooth-fix
sudo ./install.sh
```

The script handles everything automatically:
1. Installs build dependencies (`gcc`, `kernel-devel`)
2. Downloads the matching kernel source and extracts the Bluetooth driver
3. Applies the MT6639 patch to `btusb` and `btmtk`
4. Compiles patched modules against your running kernel
5. Downloads and extracts the MT6639 BT firmware from the ASUS driver package
6. Installs modules and firmware, loads the driver, and activates Bluetooth

## After a Kernel Update

When Fedora updates your kernel, the patched modules are replaced by the upstream versions. Re-run the installer:

```bash
cd mt7927-bluetooth-fix
sudo ./install.sh
```

This will rebuild and install the modules for the new kernel. The firmware only needs to be downloaded once.

## Uninstall

To restore the original upstream modules:

```bash
sudo ./uninstall.sh
```

## How It Works

The fix applies three changes to the kernel Bluetooth drivers:

### 1. btusb.c — Device ID registration
Adds the MT7927 USB IDs to the `quirks_table` with the `BTUSB_MEDIATEK` flag, so `btusb_probe()` knows to use the MediaTek firmware loading path:
```c
{ USB_DEVICE(0x13d3, 0x3588), .driver_info = BTUSB_MEDIATEK |
                                             BTUSB_WIDEBAND_SPEECH },
```

### 2. btmtk.c — MT6639 chip support
Adds the MT6639 device ID (`0x6639`) to the firmware loading logic:
- Firmware filename generation for the MT6639 naming convention
- Section filtering during firmware download (skips WiFi sections)
- Firmware persistence detection to avoid re-download on soft resets
- Hardware reset register support for the ConnectX v3 reset path

### 3. MT6639 Bluetooth firmware
The firmware (`BT_RAM_CODE_MT6639_2_1_hdr.bin`) is extracted from the official MediaTek Windows driver package distributed by ASUS. It is installed to `/lib/firmware/mediatek/mt6639/`.

## Upstream Status

As of March 2026, MT6639 Bluetooth support has **not** been merged into the mainline Linux kernel. Patches are being worked on and discussed on the linux-bluetooth mailing list. Once merged, this fix will no longer be necessary.

Related upstream work:
- [jetm/mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms) — DKMS package for both WiFi and BT (this project's patch is based on their BT patch)
- [Kernel Bugzilla](https://bugzilla.kernel.org/) — Search for MT7927 or MT6639

## Troubleshooting

**"No known MT7927/MT6639 Bluetooth USB device found"**
Your Bluetooth chip uses a different USB ID. Run `lsusb` and open an issue with the output.

**Bluetooth powered on but cannot discover devices**
```bash
bluetoothctl power off
bluetoothctl power on
bluetoothctl scan on
```

**Module loads but no controller appears**
Check `dmesg | grep -i bluetooth` for firmware loading errors. The firmware download takes ~15 seconds; wait for "Device setup" message.

**After reboot, Bluetooth is off again**
Ensure `AutoEnable=true` is set in `/etc/bluetooth/main.conf` (the installer sets this automatically).

## License

The install script and documentation are released under the MIT License.

The kernel patch is derived from [mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms) and Linux kernel source code, both under GPL-2.0.
The firmware extraction script is from the same project.
