#!/usr/bin/env bash
# Package the cross-built CMake + Ninja install tree into one archive.
# Driven by env vars so it runs identically in CI and in `docker run`, right
# after build.sh produces install/$CMAKE_VERSION-$TARGET.
#
#   PLATFORM        linux | bsd | windows | macos | android  (selects archive format)
#   TARGET          target triple (names the artifact, locates the install tree)
#   CMAKE_VERSION   Kitware/CMake tag, without the leading v (top-level dir name)
#   ROOTDIR         checkout root (default: cwd)
#   DEST            where the archive is written (default: $ROOTDIR)
#                   windows -> .7z, everything else -> .tar.xz
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${PLATFORM:?set PLATFORM}" "${TARGET:?set TARGET}" "${CMAKE_VERSION:?set CMAKE_VERSION}"
INSTALL_DIR="${INSTALL_DIR:-$ROOTDIR/install}"
DEST="${DEST:-$ROOTDIR}"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

SRC="$INSTALL_DIR/$CMAKE_VERSION-$TARGET"
[ -d "$SRC" ] || { echo "install tree not found at $SRC" >&2; exit 1; }

# Stage the tree under a plain "$CMAKE_VERSION" dir so that's the top-level path
# inside the archive (matches what releases have always shipped).
STAGE="$ROOTDIR/$CMAKE_VERSION"
rm -rf "$STAGE"
mv "$SRC" "$STAGE"

mkdir -p "$DEST"
if [ "$PLATFORM" = windows ]; then
  ARCHIVE="$DEST/cmake-$TARGET.7z"
  log "Archiving -> $ARCHIVE"
  rm -f "$ARCHIVE"
  ( cd "$ROOTDIR"
    7z a -snl -t7z -mx=9 -m0=LZMA2 -md=256m -mfb=273 -mtc=on -mmt=on "$ARCHIVE" "$CMAKE_VERSION" >/dev/null )
else
  ARCHIVE="$DEST/cmake-$TARGET.tar.xz"
  log "Archiving -> $ARCHIVE"
  tar -cf - -C "$ROOTDIR" "$CMAKE_VERSION" | xz -T0 -9e --lzma2=dict=256MiB > "$ARCHIVE"
fi
log "Done -> $ARCHIVE"
