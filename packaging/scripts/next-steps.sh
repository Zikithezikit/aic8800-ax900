#!/usr/bin/env bash
#
# next-steps.sh — print what is left to do after installing, based on actual
# detected state rather than a static checklist.
#
# Safe to re-run at any time; it changes nothing. Also printed by `make install`
# at the end, and available on its own for when someone has lost the thread:
#
#   ./packaging/scripts/next-steps.sh
#
# Deliberately NOT `set -o pipefail`. This script tests things with
# `lsmod | grep -q ...`: grep -q exits on the first match, which SIGPIPEs
# lsmod, and pipefail then reports the pipeline as failed -- so a module that
# is genuinely loaded prints as missing. Do not add pipefail back.
set -u

BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
YELLOW=$'\033[1;33m'; GREEN=$'\033[1;32m'; BLUE=$'\033[1;34m'

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s============================================================%s\n' "$BOLD" "$RESET"; }
step()  { printf '\n  %s%s %s%s\n' "$BOLD" "$1" "$2" "$RESET"; }
desc()  { printf '       %s%s%s\n' "$DIM" "$*" "$RESET"; }
cmd()   { printf '       %s%s%s\n' "$DIM" "$*" "$RESET"; }
note()  { printf '       %s%s%s\n' "$DIM" "$*" "$RESET"; }
ok()    { printf '       %sok%s   %s\n' "$GREEN" "$RESET" "$*"; }
todo()  { printf '       %sTODO%s %s\n' "$YELLOW" "$RESET" "$*"; }

# The desktop account. Never hardcoded.
TARGET_USER="${1:-${SUDO_USER:-${USER:-}}}"

head1
say "  ${BOLD}aic8800-ax900 — remaining steps${RESET}"
head1

pending=0

# ---------------------------------------------------------------------------
# 1. Real-time audio scheduling
# ---------------------------------------------------------------------------
rt_limits_present() {
    local f
    for f in /etc/security/limits.conf /etc/security/limits.d/*.conf; do
        [ -r "$f" ] || continue
        grep -qE '^[[:space:]*@]?[^#]*[[:space:]]rtprio[[:space:]]' "$f" 2>/dev/null && return 0
    done
    return 1
}

pw_is_rt() {
    pgrep -x pipewire >/dev/null 2>&1 || return 1
    [ "$(ps -L -C pipewire -o cls= 2>/dev/null | grep -c 'FF')" -gt 0 ]
}

rt_now=$(ulimit -r 2>/dev/null || echo 0)

step "1." "Real-time audio scheduling"
desc "Bluetooth audio is only stable if the audio loop runs real-time."
if pw_is_rt; then
    ok "PipeWire is running real-time (FF). Nothing to do."
elif rt_limits_present && [ "$rt_now" -gt 0 ] 2>/dev/null; then
    note "limits are in place and this session has RTPRIO = $rt_now;"
    note "PipeWire has not picked it up yet -- restart the user session."
    todo "log out and back in, then: make check"
    pending=$((pending + 1))
elif rt_limits_present; then
    say "       ${YELLOW}This session still has RLIMIT_RTPRIO = 0.${RESET}"
    say "       PAM grants that limit when a session starts, so it does not"
    say "       change until you log back in."
    todo "log out and back in  (this is the important one)"
    cmd "verify after logging in:  ps -L -C pipewire -o tid,cls,rtprio,comm"
    note "data-loop.0 should read FF, not TS"
    pending=$((pending + 1))
else
    say "       ${YELLOW}No rtprio limit is configured on this system, so the audio"
    say "       stack cannot obtain SCHED_FIFO. Bluetooth audio will stutter${RESET}"
    say "       under load with nothing appearing in any log."
    if [ -n "$TARGET_USER" ]; then
        todo "sudo make user-groups"
        note "configures $TARGET_USER and writes the limits file"
    else
        todo "sudo ./packaging/scripts/setup-user-groups.sh <username>"
    fi
    cmd "then log out and back in"
    pending=$((pending + 1))
fi

# ---------------------------------------------------------------------------
# 2. Driver loaded and firmware downloaded
# ---------------------------------------------------------------------------
step "2." "Driver"

# Snapshot once: cheaper than a fork per module, and sidesteps the pipefail
# problem above entirely because nothing here is in a pipeline.
loaded_mods=$(lsmod 2>/dev/null || true)
mod_loaded() {
    case "
$loaded_mods
" in
        *"
$1 "*[1-9]*) return 0 ;;
    esac
    return 1
}

if mod_loaded aic8800_fdrv; then
    ok "aic8800_fdrv loaded"
else
    todo "sudo modprobe aic8800_fdrv    (or replug the dongle)"
    pending=$((pending + 1))
fi

usb_id=$(lsusb 2>/dev/null | grep -i aic | sed -n 's/.*ID \([0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\}\).*/\1/p' | head -1)
case "$usb_id" in
    a69c:8d81) ok "dongle at a69c:8d81 — firmware downloaded, driver bound" ;;
    a69c:8d80) todo "dongle stuck at a69c:8d80 — firmware download failed; check: make logs" ;;
    1111:1111) todo "dongle stuck at 1111:1111 — usb_modeswitch did not run; check: make logs" ;;
    "")        todo "dongle not found on USB — plug it in" ;;
    *)         note "dongle reports $usb_id" ;;
esac

if mod_loaded aic_zlp_quirk; then
    ok "aic_zlp_quirk loaded (Bluetooth ZLP workaround)"
else
    todo "aic_zlp_quirk not loaded — Bluetooth audio will drop out; check: make logs"
    pending=$((pending + 1))
fi

# ---------------------------------------------------------------------------
# 3. Wireless connection
# ---------------------------------------------------------------------------
if command -v nmcli >/dev/null 2>&1; then
    state=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: '$1 ~ /^wl/ {print $2; exit}')
    if [ "$state" = "connected" ]; then
        ok "Wi-Fi connected"
    else
        step "3." "Wi-Fi"
        desc "The radio is up but not associated with a network yet."
        todo "nmcli device wifi list --rescan yes"
        todo "nmcli connection up <ssid>       (or: make connect SSID=<ssid>)"
        pending=$((pending + 1))
    fi
fi

# ---------------------------------------------------------------------------
# Closing: where to look next
# ---------------------------------------------------------------------------
head1
say "  ${BOLD}Useful at any time${RESET}"
cmd "make check      verify everything, non-zero exit on failure"
cmd "make status     current dongle state"
cmd "make speedtest  throughput over the air"
cmd "make fix        Bluetooth/Wi-Fi recovery"
cmd "make help       every target"
say
say "  ${BOLD}This folder is optional${RESET}"
note "The driver does not read from the checkout you installed from."
note "DKMS builds from its own copy staged in /usr/src, and the kernel"
note "loads modules from /lib/modules. You can delete the checkout and"
note "everything keeps working:"
cmd "aic8800-ax900 check      same as 'make check'"
cmd "aic8800-ax900 status     same as 'make status'"
cmd "aic8800-ax900 fix        same as 'make fix'"
cmd "aic8800-ax900 next       re-read this summary"
cmd "aic8800-ax900 uninstall  remove everything"
say
say "  ${BOLD}Docs${RESET}"
cmd "README.md               troubleshooting and architecture notes"
say

if [ "$pending" -gt 0 ]; then
    say "  ${YELLOW}${pending} item(s) above still need your attention.${RESET}"
else
    say "  ${GREEN}Nothing outstanding.${RESET}"
fi
say
exit 0