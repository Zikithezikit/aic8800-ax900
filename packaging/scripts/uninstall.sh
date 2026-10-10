#!/usr/bin/env bash
#
# uninstall.sh — remove the aic8800-ax900 driver and its configuration.
#
# Leaves /lib/firmware/aic8800* in place. Pass --purge-firmware to remove
# those too; they are inert files and harmless to keep.
#
set -euo pipefail

# Allow the Makefile to be the single source of truth for the version.
PKG="${AIC8800_PKG:-aic8800-ax900}"
VER="${AIC8800_VER:-1.0.0}"
PURGE_FW=0

usage() {
    cat <<EOF
Usage: ${0##*/} [--purge-firmware]

  --purge-firmware   also remove /lib/firmware/aic8800* (default: keep)
  -h, --help         show this message
EOF
}

for arg in "$@"; do
    case "$arg" in
        --purge-firmware) PURGE_FW=1 ;;
        -h|--help)        usage; exit 0 ;;
        *)                echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root (try: sudo $0)"; exit 1; }

log "Unloading modules"
modprobe -r aic8800_fdrv 2>/dev/null || true
modprobe -r aic_load_fw   2>/dev/null || true
modprobe -r aic_zlp_quirk 2>/dev/null || true

log "Removing DKMS package ${PKG}/${VER}"
dkms remove -m "$PKG" -v "$VER" --all 2>/dev/null || true
rm -rf "/usr/src/${PKG}-${VER}"

log "Removing configuration"
rm -fv /usr/local/bin/"$PKG"
rm -fv /etc/udev/rules.d/"${PKG}.rules"
rm -fv /etc/modprobe.d/"${PKG}.conf"
rm -fv /etc/modules-load.d/"${PKG}.conf"
# Installed by install.sh; the udev rule that invokes it is gone by now, so
# leaving the data file behind would be dead weight.
rm -fv "/etc/usb_modeswitch.d/1111:1111"

if [ "$PURGE_FW" -eq 1 ]; then
    log "Purging firmware blobs"
    rm -rf /lib/firmware/aic8800*
fi

udevadm control --reload-rules 2>/dev/null || true
depmod -a

log "Done"
dkms status | grep -i aic || echo "No aic DKMS packages remain."