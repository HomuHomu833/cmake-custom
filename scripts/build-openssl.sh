#!/usr/bin/env bash
# Cross-build static OpenSSL 1.1.1w for one target (CMake's bundled curl links it).
# Driven by env vars so it runs identically in CI and in `docker run`.
#
#   TARGET    target triple (e.g. x86_64-linux-musl, aarch64-linux-gnu,
#             aarch64-freebsd-none)
#   ROOTDIR   checkout root (default: cwd)
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${TARGET:?set TARGET}"
ARCH="${TARGET%%-*}"
OS_FIELD="$(echo "$TARGET" | cut -d- -f2)"
EXTRAS_DIR="$ROOTDIR/extras"
TC=/opt/zig-as-llvm
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# overlay the musl libc source fixes onto zig's bundled musl (lib is a+w)
[ -d "$ROOTDIR/patches/zig" ] && cp -R "$ROOTDIR/patches/zig/." /opt/zig/ || true

# 64-bit MIPS OpenSSL doesn't cross-build cleanly; build.sh also drops OpenSSL there.
case "$TARGET" in mips64*) log "OpenSSL skipped for $TARGET"; exit 0 ;; esac

# Windows (mingw) targets use llvm-mingw, not zig
case "$TARGET" in
  *-w64-mingw32)
    TC=/opt/llvm-mingw
    ZIG_CC="$TC/bin/${TARGET}-clang"; ZIG_CXX="$TC/bin/${TARGET}-clang++"
    ZIG_RANLIB="$TC/bin/${TARGET}-ranlib"
    case "$TARGET" in
      x86_64-w64-mingw32)  OPENSSL_TARGET="mingw64" ;;
      aarch64-w64-mingw32) OPENSSL_TARGET="mingw-armv8" ;;
      i686-w64-mingw32)    OPENSSL_TARGET="mingw" ;;
    esac
    log "Building OpenSSL ($TARGET -> $OPENSSL_TARGET)"
    rm -rf "$EXTRAS_DIR" "$ROOTDIR/openssl"
    fetch --dir=/tmp -o openssl.tar.gz https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz
    gzip -d < /tmp/openssl.tar.gz | tar -x -C "$ROOTDIR"
    rm -f /tmp/openssl.tar.gz
    mv "$ROOTDIR/openssl-1.1.1w" "$ROOTDIR/openssl"
    cd "$ROOTDIR/openssl"
    sed -i '/^\s*shared_cflag\s*=>\s*"-fPIC",\s*$/d' Configurations/10-main.conf
    patch -p1 < "$ROOTDIR/patches/openssl/android.patch"
    CC="$ZIG_CC" CXX="$ZIG_CXX" RANLIB="$ZIG_RANLIB" \
      ./Configure "$OPENSSL_TARGET" no-shared no-async no-tests no-dso \
        --prefix="$EXTRAS_DIR" --openssldir="/etc/ssl"
    make -j"$(nproc)"
    make install_sw
    log "Done -> $EXTRAS_DIR"
    exit 0
    ;;
esac

export ZIG_TARGET="$TARGET"
ZIG_CC="$TC/bin/cc"; ZIG_CXX="$TC/bin/c++"; ZIG_RANLIB="$TC/bin/ranlib"

# OpenSSL Configure target: by ELF arch (libc-agnostic) on Linux, BSD-* family
# otherwise. Arches OpenSSL lacks a config for fall back to a generic 32/64 one.
case "$OS_FIELD" in
  freebsd|netbsd|openbsd)
    case "$ARCH" in
      x86)                                          OPENSSL_TARGET="BSD-x86" ;;
      x86_64|x86_64h)                               OPENSSL_TARGET="BSD-x86_64" ;;
      arm|armhf|armeb|riscv32|powerpc|mips|mipsel)  OPENSSL_TARGET="BSD-generic32" ;;
      *)                                            OPENSSL_TARGET="BSD-generic64" ;;
    esac ;;
  *)
    case "$ARCH" in
      aarch64)         OPENSSL_TARGET="linux-aarch64" ;;
      aarch64_be)      OPENSSL_TARGET="linux-generic64" ;;
      arm|armhf)       OPENSSL_TARGET="linux-armv4" ;;
      armeb)           OPENSSL_TARGET="linux-generic32" ;;
      loongarch64)     OPENSSL_TARGET="linux64-loongarch64" ;;
      mips|mipsel)     OPENSSL_TARGET="linux-mips32" ;;
      powerpc)         OPENSSL_TARGET="linux-ppc" ;;
      powerpc64)       OPENSSL_TARGET="linux-ppc64" ;;
      powerpc64le)     OPENSSL_TARGET="linux-ppc64le" ;;
      riscv32|hexagon) OPENSSL_TARGET="linux-generic32" ;;
      riscv64)         OPENSSL_TARGET="linux64-riscv64" ;;
      s390x)           OPENSSL_TARGET="linux64-s390x" ;;
      x86)             OPENSSL_TARGET="linux-x86" ;;
      x86_64)          case "$TARGET" in *x32) OPENSSL_TARGET="linux-x32" ;; *) OPENSSL_TARGET="linux-x86_64" ;; esac ;;
      *)               OPENSSL_TARGET="linux-generic64" ;;
    esac ;;
esac

log "Building OpenSSL ($TARGET -> $OPENSSL_TARGET)"
rm -rf "$EXTRAS_DIR" "$ROOTDIR/openssl"
fetch --dir=/tmp -o openssl.tar.gz https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz
gzip -d < /tmp/openssl.tar.gz | tar -x -C "$ROOTDIR"
rm -f /tmp/openssl.tar.gz
mv "$ROOTDIR/openssl-1.1.1w" "$ROOTDIR/openssl"
cd "$ROOTDIR/openssl"
sed -i '/^\s*shared_cflag\s*=>\s*"-fPIC",\s*$/d' Configurations/10-main.conf
patch -p1 < "$ROOTDIR/patches/openssl/fix-io_getevents-time64.patch"
patch -p1 < "$ROOTDIR/patches/openssl/android.patch"
CC="$ZIG_CC" CXX="$ZIG_CXX" RANLIB="$ZIG_RANLIB" \
  ./Configure "$OPENSSL_TARGET" no-shared no-async no-tests no-dso \
    --prefix="$EXTRAS_DIR" --openssldir="/etc/ssl"
make -j"$(nproc)"
make install_sw
log "Done -> $EXTRAS_DIR"
