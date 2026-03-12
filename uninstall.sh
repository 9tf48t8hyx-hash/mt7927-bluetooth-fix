#!/bin/bash
# Restore original btusb/btmtk modules and remove MT6639 firmware.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo ./uninstall.sh"
    exit 1
fi

KVER=$(uname -r)
MODDIR="/lib/modules/$KVER/kernel/drivers/bluetooth"

echo "[*] Restoring original modules for kernel $KVER..."

for mod in btusb btmtk; do
    if [[ -f "$MODDIR/${mod}.ko.xz.orig" ]]; then
        mv "$MODDIR/${mod}.ko.xz.orig" "$MODDIR/${mod}.ko.xz"
        echo "    Restored ${mod}.ko.xz"
    else
        echo "    No backup found for ${mod} — skipping"
    fi
done

depmod -a "$KVER"

echo "[*] Removing MT6639 firmware..."
rm -rf /lib/firmware/mediatek/mt6639
echo "    Done"

echo "[*] Reloading original modules..."
rmmod btusb btmtk 2>/dev/null || true
sleep 1
modprobe btusb 2>/dev/null || true

echo ""
echo "[*] Uninstall complete. Bluetooth reverted to upstream drivers."
echo "    A reboot is recommended."
