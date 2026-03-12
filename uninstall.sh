#!/bin/bash
# Remove MT7927 DKMS modules and firmware, restoring upstream drivers.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo ./uninstall.sh"
    exit 1
fi

DKMS_NAME="mediatek-mt7927"
DKMS_VER="2.4"

echo "[*] Removing DKMS modules..."
dkms remove "$DKMS_NAME/$DKMS_VER" --all 2>/dev/null || echo "    DKMS module not found"
rm -rf "/usr/src/${DKMS_NAME}-${DKMS_VER}"

echo "[*] Removing MT6639/MT7927 firmware..."
rm -rf /lib/firmware/mediatek/mt6639
rm -rf /lib/firmware/mediatek/mt7927
rm -rf /usr/lib/firmware/mediatek/mt6639
rm -rf /usr/lib/firmware/mediatek/mt7927

echo "[*] Rebuilding module dependencies..."
depmod -a "$(uname -r)"

echo ""
echo "[*] Uninstall complete."
echo "    Reboot to load the upstream kernel modules."
echo "    WiFi and Bluetooth will not work until upstream support is merged."
