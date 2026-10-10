#!/usr/bin/env bash
#
# setup-user-groups.sh — let the invoking user run the audio stack in real time.
#
# Bluetooth audio glitches are frequently not a Bluetooth problem at all. If the
# desktop user cannot obtain SCHED_FIFO, PipeWire's A2DP feed loop runs at normal
# priority and gets descheduled under load. The controller's audio buffer then
# drains irregularly, which is audible as a dropout -- with no transport error,
# no HCI disconnect and nothing in the log.
#
# Two things are needed for PipeWire to go real-time:
#
#   1. the user must belong to the group that PAM grants RT priority to
#   2. a limits entry must actually grant rtprio to that group
#
# Both are set up here, and nothing is machine-specific:
#
#   * the account is taken from SUDO_USER / USER / logname, never hardcoded;
#   * only groups that exist on this system are touched;
#   * both the modern (@pipewire / @rtkit) and older (@pulse) layouts are covered;
#   * an existing limits file is detected and respected, not overwritten;
#   * membership that is already correct is skipped, so re-running is safe.
#
#   sudo make user-groups          # preferred entry point
#   sudo ./packaging/scripts/setup-user-groups.sh [user]
#
set -euo pipefail

# Candidate groups, most-preferred name first. Whatever exists here wins; the
# rest are skipped silently rather than created, since inventing groups would
# not change any PAM rule that is already on disk.
CANDIDATE_GROUPS=(pipewire rtkit pulse audio video render input bluetooth)

LIMITS_DIR=/etc/security/limits.d
LIMITS_FILE="${LIMITS_DIR}/25-pw-rlimits.conf"
# Same values upstream PipeWire documents for desktop Linux.
LIMITS_RTPRIO=95
LIMITS_NICE=-19
LIMITS_MEMLOCK=4194304

log()  { printf '  %s\n' "$*"; }
warn() { printf '  warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo make user-groups)"

# ---------------------------------------------------------------------------
# Which account?
# ---------------------------------------------------------------------------
USER_ARG="${1:-${SUDO_USER:-${USER:-}}}"
[ -n "$USER_ARG" ] || USER_ARG="$(logname 2>/dev/null || true)"

if [ -z "$USER_ARG" ]; then
    die "cannot tell which user to configure. Run this from your desktop login,
       or pass the account explicitly:  sudo $0 <username>"
fi
id "$USER_ARG" >/dev/null 2>&1 || die "no such user: $USER_ARG"

if [ "$(id -u "$USER_ARG")" -eq 0 ]; then
    die "refusing to modify the root account. Pass the desktop user explicitly:
       sudo $0 <username>"
fi

echo "==> configuring user: $USER_ARG"

# ---------------------------------------------------------------------------
# Existing RT-priority limits
# ---------------------------------------------------------------------------
have_rt_limits() {
    local f
    for f in /etc/security/limits.conf "${LIMITS_DIR}"/*.conf; do
        [ -r "$f" ] || continue
        # An rtprio rule that applies to some group or wildcard.
        if grep -qE '^[[:space:]*@]?[^#]*[[:space:]]rtprio[[:space:]]' "$f" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

rt_limits_group() {
    # Name of the group an existing rtprio rule targets, if it is group-scoped.
    local f
    for f in /etc/security/limits.conf "${LIMITS_DIR}"/*.conf; do
        [ -r "$f" ] || continue
        sed -nE 's/^[[:space:]]*@?([a-zA-Z0-9_.-]+)[[:space:]]+[^#]*rtprio.*/\1/p' "$f" 2>/dev/null | head -1
    done | head -1
}

# ---------------------------------------------------------------------------
# 1. Group membership
# ---------------------------------------------------------------------------
added=""
skipped=""
# Snapshot the current memberships once. Matching is done with a case pattern
# rather than `id -nG | grep -qx`, because grep -q exits early and under
# `pipefail` the SIGPIPE that follows makes an existing membership look absent.
existing=" $(id -nG "$USER_ARG" 2>/dev/null || true) "
for g in "${CANDIDATE_GROUPS[@]}"; do
    if ! getent group "$g" >/dev/null 2>&1; then
        continue                      # group does not exist here: skip it
    fi
    case "$existing" in
        *" $g "*) skipped="$skipped $g"; continue ;;   # already correct
    esac
    usermod -aG "$g" "$USER_ARG"
    added="$added $g"
    existing="$existing$g "
done

if [ -n "$added" ]; then
    log "added to groups:$added"
else
    log "already in every applicable group"
fi
[ -n "$skipped" ] && log "already present:$skipped"

# ---------------------------------------------------------------------------
# 2. RT priority limits, if nobody has set them up
# ---------------------------------------------------------------------------
if have_rt_limits; then
    tgt="$(rt_limits_group)"
    [ -n "$tgt" ] && log "rtprio already granted to @$tgt (limits unchanged)"
else
    log "no rtprio limit found anywhere; writing $LIMITS_FILE"
    cat > "$LIMITS_FILE" <<EOF
# Written by aic8800-ax900 (packaging/scripts/setup-user-groups.sh).
#
# Grants real-time scheduling to the desktop user running PipeWire. Without it
# PipeWire cannot use SCHED_FIFO, and Bluetooth audio drops out under load with
# nothing appearing in any log. Same values PipeWire upstream documents.
#
# Takes effect at the next login.
@pipewire   - rtprio  $LIMITS_RTPRIO
@pipewire   - nice    $LIMITS_NICE
@pipewire   - memlock $LIMITS_MEMLOCK
EOF
    chmod 0644 "$LIMITS_FILE"
fi

# ---------------------------------------------------------------------------
# 3. Verify a PAM session would actually receive the limits
# ---------------------------------------------------------------------------
probe=/tmp/.aic8800-rtcheck.$$
cat > "$probe" <<'EOF'
#!/bin/sh
printf 'rtprio=%s\n' "$(ulimit -r)"
EOF
chmod +x "$probe"

rt=$(su - "$USER_ARG" -c "$probe" 2>/dev/null | sed -n 's/^rtprio=//p') || rt=""
rm -f "$probe"

echo
if [ -n "$rt" ] && [ "$rt" -gt 0 ] 2>/dev/null; then
    log "verified: a fresh login will get RLIMIT_RTPRIO = $rt"
    echo
    echo "Log out and back in for this to take effect."
    echo "Then confirm with:  ps -L -C pipewire -o tid,cls,rtprio,comm"
    echo "  cls should read FF (SCHED_FIFO) for data-loop.0, not TS."
elif [ -n "$rt" ] && [ "$rt" = "0" ]; then
    warn "a PAM session for $USER_ARG still gets RLIMIT_RTPRIO = 0."
    warn "Check that pam_limits.so is enabled in the display manager's PAM"
    warn "stack (sddm, gdm-password, login, ...)."
else
    log "could not verify with su (this shell's login shell may not be POSIX sh)."
    log "Check after logging in:  ulimit -r   -- expect 95"
fi