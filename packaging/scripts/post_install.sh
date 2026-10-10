#!/bin/sh
# Install the AIC8800 firmware blobs that aic_load_fw / aic8800_fdrv request
# via request_firmware(). Runs from DKMS's POST_INSTALL hook.
set -e

# dkms sets $PACKAGE_NAME / $PACKAGE_VERSION / $DEST_MODULE_LOCATION when it
# sources this; fall back to the conventional /usr/src layout when run by hand.
: "${PACKAGE_NAME:=aic8800-ax900}"
: "${PACKAGE_VERSION:=1.0.0}"

SRC="${1:-/usr/src/${PACKAGE_NAME}-${PACKAGE_VERSION}/fw}"

[ -d "$SRC" ] || { echo "post_install: no firmware source at $SRC, skipping"; exit 0; }

for d in "$SRC"/aic8800*; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    dst="/lib/firmware/$name"
    mkdir -p "$dst"
    # -u: refresh in place, but keep the tree's own timestamps so DKMS's
    # per-kernel "differences between built and installed" check stays quiet.
    cp -u "$d"/* "$dst"/ 2>/dev/null || cp "$d"/* "$dst"/
    echo "post_install: firmware $name -> $dst ($(ls -1 "$dst" | wc -l) files)"
done

exit 0