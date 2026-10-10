#!/usr/bin/env bash
#
# stage.sh — copy this repository to /usr/src so DKMS can build it.
#
# DKMS requires two things that the repository layout deliberately does not
# provide at its root:
#   * <source_dir>/dkms.conf        (ours lives at packaging/dkms.conf)
#   * a plain source tree it can copy into /var/lib/dkms
#
# Both `make install` and this script's callers use it, so there is exactly one
# definition of what a staged tree looks like.
#
#   sudo ./packaging/scripts/stage.sh [repo_dir] [stage_dir]
#
set -euo pipefail

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PKG="${AIC8800_PKG:-aic8800-ax900}"
VER="${AIC8800_VER:-1.0.0}"
DEST="${2:-/usr/src/${PKG}-${VER}}"

die() {
  echo "stage: $*" >&2
  exit 1
}

[ -f "$REPO/packaging/dkms.conf" ] || die "no packaging/dkms.conf in $REPO"

# dkms.conf has to spell PACKAGE_NAME/PACKAGE_VERSION literally, so it cannot
# read them from the environment. Verify here that it still agrees with the
# Makefile, rather than letting a version bump land in one file only and
# produce a DKMS tree that silently builds under the wrong name.
for kv in "PACKAGE_NAME=\"$PKG\"" "PACKAGE_VERSION=\"$VER\""; do
  grep -qF "$kv" "$REPO/packaging/dkms.conf" ||
    die "packaging/dkms.conf disagrees with PKG/VERSION: expected $kv"
done

rm -rf "$DEST"
mkdir -p "$DEST"

# Keep the staged tree lean: DKMS re-copies it on every kernel install, and
# neither .git nor build artefacts belong in it.
rsync -a \
  --exclude='.git' \
  --exclude='build/' \
  --exclude='*.o' --exclude='*.ko' --exclude='*.mod*' \
  --exclude='*.symvers' --exclude='*.order' --exclude='.*.cmd' \
  --exclude='.tmp_versions' --exclude='modules.order' \
  "$REPO"/ "$DEST"/

# DKMS only looks for dkms.conf at the root of the source dir.
install -m 0644 "$REPO/packaging/dkms.conf" "$DEST/dkms.conf"

chmod +x "$DEST"/packaging/scripts/*.sh

echo "stage: $REPO -> $DEST ($(du -sh "$DEST" | cut -f1))"
