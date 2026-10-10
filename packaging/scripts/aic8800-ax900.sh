#!/bin/sh
# aic8800-ax900 — driver management without the source checkout.
#
# Installed by `make install` to /usr/local/bin. The checkout you ran
# `make install` from is disposable: DKMS builds from its own copy staged in
# /usr/src, and the kernel loads modules from /lib/modules. Deleting the
# checkout does not affect the driver.
#
# This wrapper keeps the operational commands available regardless, by
# delegating to the staged tree.
#
#   aic8800-ax900 check     verify everything
#   aic8800-ax900 status    current dongle state
#   aic8800-ax900 fix       Bluetooth/Wi-Fi recovery
#   aic8800-ax900 next      what is left to do
#   aic8800-ax900 uninstall remove everything
#   aic8800-ax900 help      all targets
#
set -u

# Locate the staged tree instead of hardcoding the version, so this wrapper
# keeps working across a package version bump.
STAGE=$(ls -d /usr/src/aic8800-ax900-*/ 2>/dev/null | sort -V | tail -1)
STAGE=${STAGE%/}

if [ -z "$STAGE" ] || [ ! -f "$STAGE/Makefile" ]; then
    printf 'aic8800-ax900: staged tree missing under /usr/src\n' >&2
    printf 'The driver has been uninstalled, or was never installed from this package.\n' >&2
    exit 1
fi

# `next` is not a make target; the summary lives in the staged tree already.
if [ "${1:-}" = "next" ]; then
    exec "$STAGE/packaging/scripts/next-steps.sh"
fi

# Targets that must run as root. sudo is skipped when already root.
# Derived from the Makefile's own .PHONY list intersected with the targets that
# need privilege, so it cannot drift out of date when a target is added.
NEED_ROOT=" install uninstall reinstall firmware user-groups fix connect \
            disconnect debug-on debug-off relink logs scan check "

want=""
for arg in "$@"; do
    case " $NEED_ROOT " in
        *" $arg "*) want=1; break ;;
    esac
done

if [ -n "$want" ] && [ "$(id -u)" -ne 0 ]; then
    exec sudo make -C "$STAGE" "$@"
fi

exec make -C "$STAGE" "$@"