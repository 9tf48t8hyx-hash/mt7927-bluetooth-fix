#!/bin/bash
# mt7927-fix — One-shot DKMS installer for MediaTek MT7927 WiFi & Bluetooth on Linux
#
# Fixes both WiFi (PCIe mt7925e) and Bluetooth (USB btusb/btmtk) for the
# MediaTek Filogic 380 (MT7927/MT6639) combo chip found on recent AM5 boards.
#
# Usage: sudo ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DKMS_NAME="mediatek-mt7927"
DKMS_VER="2.4"
BUILDDIR="$SCRIPT_DIR/_build"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root: sudo ./install.sh"
    exit 1
fi

KVER=$(uname -r)
KMAJOR="${KVER%%.*}"
KBASE="${KVER%%-*}"
info "Kernel: $KVER"

# ── Step 1: Dependencies ──────────────────────────────────────────

info "Installing build dependencies..."
if command -v dnf &>/dev/null; then
    dnf install -y gcc kernel-devel-"$KVER" dkms curl xz python3 2>&1 | tail -3
elif command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y gcc linux-headers-"$KVER" dkms curl xz-utils python3 2>&1 | tail -3
else
    error "Unsupported package manager. Install gcc, kernel-devel, dkms, curl, xz, python3."
    exit 1
fi

KSRC="/usr/src/kernels/$KVER"
[[ ! -d "$KSRC" ]] && KSRC="/lib/modules/$KVER/build"
if [[ ! -d "$KSRC" ]]; then
    error "Kernel headers not found for $KVER"
    exit 1
fi

# ── Step 2: Download kernel source ────────────────────────────────

TARBALL="linux-${KBASE}.tar.xz"
mkdir -p "$BUILDDIR"

if [[ ! -f "$BUILDDIR/$TARBALL" ]]; then
    info "Downloading kernel $KBASE source..."
    curl -sL -o "$BUILDDIR/$TARBALL" \
        "https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/$TARBALL"
fi
info "Kernel tarball: $(du -h "$BUILDDIR/$TARBALL" | cut -f1)"

# ── Step 3: Extract driver sources ────────────────────────────────

info "Extracting bluetooth driver sources..."
rm -rf "$BUILDDIR/bluetooth"
mkdir -p "$BUILDDIR/bluetooth"
tar -xf "$BUILDDIR/$TARBALL" \
    --strip-components=3 \
    -C "$BUILDDIR/bluetooth" \
    "linux-${KBASE}/drivers/bluetooth"

info "Extracting mt76 WiFi driver sources..."
rm -rf "$BUILDDIR/mt76"
mkdir -p "$BUILDDIR/mt76"
tar -xf "$BUILDDIR/$TARBALL" \
    --strip-components=6 \
    -C "$BUILDDIR/mt76" \
    "linux-${KBASE}/drivers/net/wireless/mediatek/mt76"

# ── Step 4: Apply patches ─────────────────────────────────────────

info "Applying Bluetooth MT6639 patch..."
patch -d "$BUILDDIR/bluetooth" -p3 < "$SCRIPT_DIR/mt6639-bt.patch"
cp "$SCRIPT_DIR/bluetooth.Makefile" "$BUILDDIR/bluetooth/Makefile"

info "Applying WiFi MT7927 patches..."
patch -d "$BUILDDIR/mt76" -p1 < "$SCRIPT_DIR/mt7902-wifi-6.19.patch"
for p in "$SCRIPT_DIR"/mt7927-wifi-*.patch; do
    echo "  $(basename "$p")"
    patch -d "$BUILDDIR/mt76" -p1 < "$p"
done

# Install Kbuild files
cp "$SCRIPT_DIR/mt76.Kbuild"   "$BUILDDIR/mt76/Kbuild"
cp "$SCRIPT_DIR/mt7921.Kbuild" "$BUILDDIR/mt76/mt7921/Kbuild"
cp "$SCRIPT_DIR/mt7925.Kbuild" "$BUILDDIR/mt76/mt7925/Kbuild"

# ── Step 5: Download and extract firmware ─────────────────────────

FW_BT="/lib/firmware/mediatek/mt6639/BT_RAM_CODE_MT6639_2_1_hdr.bin"
FW_WIFI="/lib/firmware/mediatek/mt7927/WIFI_RAM_CODE_MT6639_2_1.bin"

if [[ ! -f "$FW_BT" ]] || [[ ! -f "$FW_WIFI" ]]; then
    info "Downloading MediaTek driver package (for firmware)..."
    cd "$SCRIPT_DIR"
    bash download-driver.sh "$BUILDDIR"

    info "Extracting firmware..."
    DRIVER_ZIP=$(ls "$BUILDDIR"/DRV_WiFi_MTK_MT7925_MT7927*.zip 2>/dev/null | head -1)
    if [[ -z "$DRIVER_ZIP" ]]; then
        error "Driver ZIP not found."
        exit 1
    fi
    mkdir -p "$BUILDDIR/firmware"
    python3 "$SCRIPT_DIR/extract_firmware.py" "$DRIVER_ZIP" "$BUILDDIR/firmware"

    # Install firmware
    mkdir -p /lib/firmware/mediatek/mt6639 /lib/firmware/mediatek/mt7927
    # Also install to /usr/lib/firmware if it exists (Fedora uses both)
    for fwdir in /lib/firmware /usr/lib/firmware; do
        if [[ -d "$fwdir" ]]; then
            mkdir -p "$fwdir/mediatek/mt6639" "$fwdir/mediatek/mt7927"
            cp "$BUILDDIR/firmware/BT_RAM_CODE_MT6639_2_1_hdr.bin" "$fwdir/mediatek/mt6639/"
            cp "$BUILDDIR/firmware/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin" "$fwdir/mediatek/mt7927/"
            cp "$BUILDDIR/firmware/WIFI_RAM_CODE_MT6639_2_1.bin" "$fwdir/mediatek/mt7927/"
        fi
    done
    info "Firmware installed"
else
    info "Firmware already installed, skipping"
fi

# ── Step 6: Install DKMS ──────────────────────────────────────────

DKMS_SRC="/usr/src/${DKMS_NAME}-${DKMS_VER}"

info "Installing DKMS source tree..."

# Remove previous DKMS version if present
dkms status "$DKMS_NAME/$DKMS_VER" 2>/dev/null | grep -q "$DKMS_NAME" && \
    dkms remove "$DKMS_NAME/$DKMS_VER" --all 2>/dev/null || true

rm -rf "$DKMS_SRC"
mkdir -p "$DKMS_SRC/drivers/bluetooth" "$DKMS_SRC/mt76/mt7921" "$DKMS_SRC/mt76/mt7925"

# Copy DKMS config
cp "$SCRIPT_DIR/dkms.conf" "$DKMS_SRC/"

# Copy patched sources
cp "$BUILDDIR"/bluetooth/*.c "$BUILDDIR"/bluetooth/*.h "$DKMS_SRC/drivers/bluetooth/"
cp "$BUILDDIR/bluetooth/Makefile" "$DKMS_SRC/drivers/bluetooth/"
cp "$BUILDDIR"/mt76/*.c "$BUILDDIR"/mt76/*.h "$DKMS_SRC/mt76/"
cp "$BUILDDIR/mt76/Kbuild" "$DKMS_SRC/mt76/"
cp "$BUILDDIR"/mt76/mt7921/*.c "$BUILDDIR"/mt76/mt7921/*.h "$DKMS_SRC/mt76/mt7921/"
cp "$BUILDDIR/mt76/mt7921/Kbuild" "$DKMS_SRC/mt76/mt7921/"
cp "$BUILDDIR"/mt76/mt7925/*.c "$BUILDDIR"/mt76/mt7925/*.h "$DKMS_SRC/mt76/mt7925/"
cp "$BUILDDIR/mt76/mt7925/Kbuild" "$DKMS_SRC/mt76/mt7925/"

info "Building and installing DKMS modules..."
dkms add "$DKMS_NAME/$DKMS_VER" 2>/dev/null || true
dkms build "$DKMS_NAME/$DKMS_VER" -k "$KVER"
dkms install "$DKMS_NAME/$DKMS_VER" -k "$KVER" --force

# ── Step 7: Load modules and activate ─────────────────────────────

info "Loading modules..."

# Reload BT
rmmod btusb btmtk 2>/dev/null || true
sleep 1
modprobe btmtk
modprobe btusb
sleep 5

# Load WiFi
modprobe mt7925e 2>/dev/null || true
sleep 3

# Activate Bluetooth
rfkill unblock bluetooth 2>/dev/null || true
if command -v bluetoothctl &>/dev/null; then
    bluetoothctl power on 2>/dev/null || true
fi

# Auto-enable BT at boot
if [[ -f /etc/bluetooth/main.conf ]]; then
    sed -i 's/^#\?AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf
fi

# ── Result ────────────────────────────────────────────────────────

echo ""
info "Installation complete!"
echo ""

# WiFi status
WIFI_IF=$(ip -o link show | grep -oP 'wl\S+(?=:)' | head -1)
if [[ -n "$WIFI_IF" ]]; then
    info "WiFi interface: $WIFI_IF"
else
    warn "WiFi interface not yet visible. A reboot is recommended."
fi

# BT status
if command -v bluetoothctl &>/dev/null && bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then
    info "Bluetooth is UP and running"
    bluetoothctl show 2>/dev/null | grep -E "Controller|Name" | head -2
else
    warn "Bluetooth controller may need a reboot to fully initialize."
fi

echo ""
echo "  A reboot is recommended for clean module loading."
echo "  DKMS will automatically rebuild modules on kernel updates."
echo ""
