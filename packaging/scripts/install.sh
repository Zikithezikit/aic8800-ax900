#!/usr/bin/env bash
#
# install.sh — deploy the AIC8800D80 driver on this system.
#
# Replaces the aic8800/radxa DKMS package (which builds but binds neither
# stage of this dongle's boot handshake). Safe to re-run.
#
#   sudo make install                    # preferred entry point
#   sudo ./packaging/scripts/install.sh   # equivalent
#   sudo ./packaging/scripts/install.sh --all-kernels
#   sudo ./packaging/scripts/install.sh --no-user-groups
#
# The install is complete in one step: it also configures the invoking user for
# real-time audio, then prints whatever is left to do (a re-login, usually).
# Pass --no-user-groups to skip touching accounts.
#
# Requires: dkms, make, gcc, rsync. Optional but recommended: usb_modeswitch
# (without it a dongle that enumerates as 1111:1111 stays in mass-storage
# mode).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Allow the Makefile to be the single source of truth for the version.
PKG="${AIC8800_PKG:-aic8800-ax900}"
VER="${AIC8800_VER:-1.0.0}"
DKMS_SRC="/usr/src/${PKG}-${VER}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0)"

usage() {
    cat <<EOF
Usage: ${0##*/} [--all-kernels] [--no-user-groups]

  --all-kernels      build and install for every kernel in /lib/modules
                     (default: only the running kernel, \`uname -r\`)
  --no-user-groups   do not add the invoking user to audio groups or write
                     an rtprio limits file
  -h, --help         show this message
EOF
}

ALL_KERNELS=0
USER_GROUPS=1
for arg in "$@"; do
    case "$arg" in
        --all-kernels)   ALL_KERNELS=1 ;;
        --no-user-groups) USER_GROUPS=0 ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "unknown option: $arg (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
log "Checking prerequisites"
# ---------------------------------------------------------------------------
for c in dkms make gcc rsync; do
    command -v "$c" >/dev/null || die "$c not installed"
done
if command -v usb_modeswitch >/dev/null; then
    log "usb_modeswitch: $(command -v usb_modeswitch)"
else
    warn "usb_modeswitch not found. Without it a dongle that enumerates as"
    warn "1111:1111 will stay in mass-storage mode. Install: apt install usb-modeswitch"
fi

# ---------------------------------------------------------------------------
log "Removing the superseded aic8800/radxa package"
# ---------------------------------------------------------------------------
if dkms status 2>/dev/null | grep -q '^aic8800/radxa'; then
    dkms remove -m aic8800 -v radxa --all || \
        warn "dkms remove aic8800/radxa failed; continuing"
    # The radxa dkms.conf references a build/ directory that no longer exists,
    # which is what leaves it as an un-removable zombie. Sweep the leftovers.
    rm -rf /var/lib/dkms/aic8800
    rm -f  /lib/modules/*/updates/dkms/aic8800_fdrv.ko* \
           /lib/modules/*/updates/dkms/aic_load_fw.ko*
    log "removed"
else
    log "not present"
fi

# ---------------------------------------------------------------------------
log "Staging source tree at ${DKMS_SRC}"
# ---------------------------------------------------------------------------
"$REPO/packaging/scripts/stage.sh" "$REPO" "$DKMS_SRC"

# ---------------------------------------------------------------------------
log "DKMS add"
# ---------------------------------------------------------------------------
dkms remove -m "$PKG" -v "$VER" --all >/dev/null 2>&1 || true
dkms add -m "$PKG" -v "$VER"

kernels=()
if [ "$ALL_KERNELS" -eq 1 ]; then
    while read -r k; do
        [ -d "/lib/modules/$k/build" ] && kernels+=("$k")
    done < <(ls /lib/modules)
else
    kernels=("$(uname -r)")
fi
[ "${#kernels[@]}" -gt 0 ] || die "no buildable kernels found"

# ---------------------------------------------------------------------------
for k in "${kernels[@]}"; do
    log "DKMS build + install for $k"
    dkms build -m "$PKG" -v "$VER" -k "$k" 2>&1 | tail -3
    dkms install -m "$PKG" -v "$VER" -k "$k" 2>&1 | grep -Ev '^Signing|^Sign ' | tail -5
done

# ---------------------------------------------------------------------------
log "Installing udev, modprobe.d and modules-load.d configuration"
# ---------------------------------------------------------------------------
install -m 0644 "$REPO/packaging/udev/50-aic8800-ax900.rules" \
          /etc/udev/rules.d/50-aic8800-ax900.rules
install -m 0644 "$REPO/packaging/modprobe.d/aic8800-ax900.conf" \
          /etc/modprobe.d/aic8800-ax900.conf
install -m 0644 "$REPO/packaging/modules-load.d/aic8800-ax900.conf" \
          /etc/modules-load.d/aic8800-ax900.conf

# usb_modeswitch data file (git cannot hold a colon in a filename, so the repo
# stores it as 1111_1111).
if [ -f "$REPO/packaging/usb_modeswitch/1111_1111" ]; then
    install -m 0644 "$REPO/packaging/usb_modeswitch/1111_1111" \
            /etc/usb_modeswitch.d/1111:1111
fi

# Superseded: shipped by an earlier AIC installer, and names a module
# (aic_btusb) that no DKMS package builds.
if [ -f /etc/modules-load.d/aic8800.conf ]; then
    rm -f /etc/modules-load.d/aic8800.conf
    log "removed stale /etc/modules-load.d/aic8800.conf (referenced nonexistent aic_btusb)"
fi

# A command that works without the checkout. Installed last, so that if the
# checkout is deleted straight after install, status/check/fix are still there.
install -m 0755 "$REPO/packaging/scripts/aic8800-ax900.sh" /usr/local/bin/aic8800-ax900
log "installed /usr/local/bin/aic8800-ax900 (works without this folder)"

udevadm control --reload-rules
udevadm trigger --subsystem-match=usb 2>/dev/null || true

# ---------------------------------------------------------------------------
if [ "$USER_GROUPS" -eq 1 ]; then
    log "Configuring the desktop user for real-time audio"
    # Non-fatal: a failed group change must not roll back a working driver, and
    # the summary at the end reports it rather than hiding it.
    if "$REPO/packaging/scripts/setup-user-groups.sh" 2>&1 | sed 's/^/  /'; then
        :
    else
        warn "could not configure user groups; run later: sudo make user-groups"
    fi
else
    log "Skipping user group setup (--no-user-groups)"
fi

# ---------------------------------------------------------------------------
log "Loading modules"
# ---------------------------------------------------------------------------
modprobe -r aic8800_fdrv 2>/dev/null || true
modprobe aic_load_fw
modprobe aic8800_fdrv || warn "aic8800_fdrv did not load; replug the dongle"

# ---------------------------------------------------------------------------
log "Result"
# ---------------------------------------------------------------------------
dkms status | grep "^${PKG}" || true
lsmod | grep -E '^aic' || warn "no aic modules loaded"
echo
if ip link show 2>/dev/null | grep -q wlx; then
    echo "Wi-Fi interface:"
    iw dev | sed 's/^/  /'
else
    echo "No wlan interface yet. Replug the dongle, or check: dmesg | grep -i aic"
fi
echo
echo "Done installing. What is left to do, and why, follows."
echo

# The summary must reflect the desktop session rather than root's shell:
# RLIMIT_RTPRIO is a per-session limit, so a root shell would always report 0
# and would tell the user to do something that is already done.
if [ -n "${SUDO_USER:-}" ] && id -u "$SUDO_USER" >/dev/null 2>&1; then
    # -s /bin/bash is essential: without it su runs the script with the
    # account's login shell, and where that is not a POSIX shell the script is
    # silently interpreted by the wrong interpreter and reports bogus state.
    su - "$SUDO_USER" -s /bin/bash -c "$REPO/packaging/scripts/next-steps.sh" 2>/dev/null \
        || "$REPO/packaging/scripts/next-steps.sh"
else
    "$REPO/packaging/scripts/next-steps.sh"
fi