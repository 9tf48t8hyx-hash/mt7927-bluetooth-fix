#!/bin/bash
# mt7927-bluetooth-fix — One-shot installer for MediaTek MT7927/MT6639 Bluetooth on Fedora
# Fixes Bluetooth on motherboards using the MediaTek Filogic 380 (MT7927) combo chip,
# where the BT controller (MT6639) connects via USB but is not recognized by the
# upstream btusb/btmtk kernel drivers.
#
# Tested on: Fedora 43 (kernel 6.19.x), ASUS ROG Strix X870-I Gaming WiFi
# Should work on: Fedora 41+, kernel 6.12+, any board with MT7927 BT (13d3:3588 and others)
#
# Usage: sudo ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }

# ── Pre-flight checks ──────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo ./install.sh)"
    exit 1
fi

KVER=$(uname -r)
info "Kernel: $KVER"

# Verify the BT device is present
if ! lsusb 2>/dev/null | grep -qiE "13d3:3588|0489:e13a|0489:e0fa|0489:e10f|0489:e110|0489:e116"; then
    error "No known MT7927/MT6639 Bluetooth USB device found."
    echo "  This fix targets devices with the following USB IDs:"
    echo "    13d3:3588 (IMC Networks / ASUS)"
    echo "    0489:e13a, 0489:e0fa, 0489:e10f, 0489:e110, 0489:e116 (Foxconn)"
    echo ""
    echo "  Your USB Bluetooth devices:"
    lsusb | grep -iE "bluetooth|wireless" || echo "    (none found)"
    exit 1
fi

BT_USB_ID=$(lsusb | grep -oiE "(13d3:3588|0489:e13a|0489:e0fa|0489:e10f|0489:e110|0489:e116)" | head -1)
info "Found MT7927 BT device: $BT_USB_ID"

# ── Step 1: Install dependencies ───────────────────────────────────

info "Installing build dependencies..."
if command -v dnf &>/dev/null; then
    dnf install -y gcc kernel-devel-"$KVER" curl xz python3 2>&1 | tail -3
elif command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y gcc linux-headers-"$KVER" curl xz-utils python3 2>&1 | tail -3
else
    error "Unsupported package manager. Install gcc, kernel-devel, curl, xz, python3 manually."
    exit 1
fi

KSRC="/usr/src/kernels/$KVER"
if [[ ! -d "$KSRC" ]]; then
    KSRC="/lib/modules/$KVER/build"
fi
if [[ ! -d "$KSRC" ]]; then
    error "Kernel headers not found for $KVER"
    exit 1
fi
info "Kernel headers: $KSRC"

# ── Step 2: Download kernel source (bluetooth driver only) ─────────

KMAJOR="${KVER%%.*}"
KBASE="${KVER%%-*}"
TARBALL="linux-${KBASE}.tar.xz"
BUILDDIR="$SCRIPT_DIR/_build"

mkdir -p "$BUILDDIR"

if [[ ! -f "$BUILDDIR/$TARBALL" ]]; then
    info "Downloading kernel $KBASE source..."
    curl -sL -o "$BUILDDIR/$TARBALL" \
        "https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/$TARBALL"
fi
info "Kernel tarball: $(du -h "$BUILDDIR/$TARBALL" | cut -f1)"

info "Extracting bluetooth driver sources..."
rm -rf "$BUILDDIR/bluetooth"
mkdir -p "$BUILDDIR/bluetooth"
tar -xf "$BUILDDIR/$TARBALL" \
    --strip-components=3 \
    -C "$BUILDDIR/bluetooth" \
    "linux-${KBASE}/drivers/bluetooth"

# ── Step 3: Apply MT6639 patch ─────────────────────────────────────

info "Applying MT6639 Bluetooth patch..."
cd "$BUILDDIR/bluetooth"
patch -p3 < "$SCRIPT_DIR/mt6639-bt.patch"

# ── Step 4: Build modules ─────────────────────────────────────────

info "Compiling btusb and btmtk modules..."
cat > Makefile <<'MKEOF'
obj-m += btusb.o
obj-m += btmtk.o
MKEOF

make -C "$KSRC" M="$(pwd)" modules 2>&1 | grep -E "^(  CC|  LD|  BTF|ERROR|make)" || true

if [[ ! -f btusb.ko ]] || [[ ! -f btmtk.ko ]]; then
    error "Module compilation failed."
    exit 1
fi
info "Modules built successfully"

# ── Step 5: Download and extract firmware ──────────────────────────

if [[ ! -f /lib/firmware/mediatek/mt6639/BT_RAM_CODE_MT6639_2_1_hdr.bin ]]; then
    info "Downloading MediaTek driver package (for firmware extraction)..."
    cd "$SCRIPT_DIR"
    bash download-driver.sh "$BUILDDIR"

    info "Extracting MT6639 Bluetooth firmware..."
    DRIVER_ZIP=$(ls "$BUILDDIR"/DRV_WiFi_MTK_MT7925_MT7927*.zip 2>/dev/null | head -1)
    if [[ -z "$DRIVER_ZIP" ]]; then
        error "Driver ZIP not found after download."
        exit 1
    fi

    mkdir -p "$BUILDDIR/firmware"
    python3 "$SCRIPT_DIR/extract_firmware.py" "$DRIVER_ZIP" "$BUILDDIR/firmware"

    mkdir -p /lib/firmware/mediatek/mt6639
    cp "$BUILDDIR/firmware/BT_RAM_CODE_MT6639_2_1_hdr.bin" \
       /lib/firmware/mediatek/mt6639/
    info "Firmware installed: /lib/firmware/mediatek/mt6639/"
else
    info "Firmware already installed, skipping"
fi

# ── Step 6: Install modules ───────────────────────────────────────

MODDIR="/lib/modules/$KVER/kernel/drivers/bluetooth"
cd "$BUILDDIR/bluetooth"

# Backup originals (only if not already backed up)
for mod in btusb btmtk; do
    if [[ -f "$MODDIR/${mod}.ko.xz" ]] && [[ ! -f "$MODDIR/${mod}.ko.xz.orig" ]]; then
        cp "$MODDIR/${mod}.ko.xz" "$MODDIR/${mod}.ko.xz.orig"
    fi
done
info "Original modules backed up (.orig)"

# Install patched modules
for mod in btusb btmtk; do
    rm -f "$MODDIR/${mod}.ko.xz" "$MODDIR/${mod}.ko.zst"
    xz -C crc32 -T0 "${mod}.ko" -c > "$MODDIR/${mod}.ko.xz"
done
depmod -a "$KVER"
info "Patched modules installed"

# ── Step 7: Load and activate ─────────────────────────────────────

info "Loading patched modules..."
rmmod btusb btmtk 2>/dev/null || true
sleep 1
modprobe btmtk
modprobe btusb
sleep 15

rfkill unblock bluetooth 2>/dev/null || true
bluetoothctl power on 2>/dev/null || true
sleep 2

# Enable auto-power at boot
if [[ -f /etc/bluetooth/main.conf ]]; then
    sed -i 's/^#\?AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf
fi

# ── Verify ────────────────────────────────────────────────────────

echo ""
if bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then
    info "Bluetooth is UP and running!"
    bluetoothctl show 2>/dev/null | grep -E "Controller|Name|Powered" | head -3
else
    warn "Bluetooth controller detected but not yet powered on."
    warn "Try: rfkill unblock bluetooth && bluetoothctl power on"
fi

echo ""
info "Installation complete."
echo ""
echo "  Notes:"
echo "    - Original modules saved as .orig in $MODDIR"
echo "    - To restore: rename .orig back to .ko.xz and run depmod -a"
echo "    - After a kernel update, re-run this script for the new kernel"
echo ""
