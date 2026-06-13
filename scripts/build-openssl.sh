#!/usr/bin/env bash
# Cross-build static OpenSSL (default 3.6.3) for one target; CMake's curl links it.
# Driven by env vars so it runs identically in CI and in `docker run`.
#
#   TARGET    target triple (e.g. x86_64-linux-musl, aarch64-linux-gnu,
#             aarch64-freebsd-none, aarch64-linux-android, arm64-apple-darwin,
#             x86_64-w64-mingw32)
#   ROOTDIR   checkout root (default: cwd)
#   NDK_VERSION/NDK_REVISION  official NDK for the android clang (android only)
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${TARGET:?set TARGET}"
ARCH="${TARGET%%-*}"
OS_FIELD="$(echo "$TARGET" | cut -d- -f2)"
EXTRAS_DIR="$ROOTDIR/extras"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

OPENSSL_VERSION="${OPENSSL_VERSION:-3.6.3}"

# --- per-platform compiler + OpenSSL Configure target -----------------------
# APPLY_PATCHES gates the android source patch; off for mingw/macos (the cert
# bundle is a bionic on-device concern and pulls POSIX dirent code those lack).
# CC/CXX/AR/RANLIB select the toolchain — AR matters for macOS (ld64 rejects a
# GNU-format archive, so OpenSSL must use the cctools ar).
APPLY_PATCHES=1
SSL_EXTRA=""
case "$TARGET" in
  *-w64-mingw32)
    TC=/opt/llvm-mingw
    CC="$TC/bin/${TARGET}-clang"; CXX="$TC/bin/${TARGET}-clang++"
    AR="$TC/bin/${TARGET}-ar"; RANLIB="$TC/bin/${TARGET}-ranlib"
    # OpenSSL's mingw build calls bare `windres`; llvm-mingw ships it prefixed.
    export RC="$TC/bin/${TARGET}-windres"; export WINDRES="$RC"
    APPLY_PATCHES=0
    case "$TARGET" in
      x86_64-w64-mingw32)  OPENSSL_TARGET="mingw64" ;;
      aarch64-w64-mingw32) OPENSSL_TARGET="mingwarm64" ;;   # OpenSSL 3.6+
      i686-w64-mingw32)    OPENSSL_TARGET="mingw" ;;
    esac ;;
  *-linux-android*)
    : "${NDK_VERSION:?set NDK_VERSION for the android build}"
    NDK_REVISION="${NDK_REVISION:-}"
    API="${ANDROID_PLATFORM:-25}"; [ "$TARGET" = riscv64-linux-android ] && API=35
    NDK_NAME="android-ndk-r${NDK_VERSION}${NDK_REVISION}"; NDK_DIR="$ROOTDIR/$NDK_NAME"
    if [ ! -d "$NDK_DIR" ]; then
      log "Downloading official NDK ($NDK_NAME)"
      fetch --dir="$ROOTDIR" -o ndk.zip "https://dl.google.com/android/repository/${NDK_NAME}-linux.zip"
      unzip -qq "$ROOTDIR/ndk.zip" -d "$ROOTDIR"; rm -f "$ROOTDIR/ndk.zip"
    fi
    TC="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
    CC="$TC/bin/${TARGET}${API}-clang"; CXX="${CC}++"
    AR="$TC/bin/llvm-ar"; RANLIB="$TC/bin/llvm-ranlib"
    # CC-driven linux-* configs (the NDK clang handles the bionic specifics).
    case "$ARCH" in
      aarch64) OPENSSL_TARGET="linux-aarch64" ;;
      armv7a)  OPENSSL_TARGET="linux-armv4" ;;
      i686)    OPENSSL_TARGET="linux-x86" ;;
      x86_64)  OPENSSL_TARGET="linux-x86_64" ;;
      riscv64) OPENSSL_TARGET="linux64-riscv64" ;;
      *)       OPENSSL_TARGET="linux-generic64" ;;
    esac
    # 32-bit x86 OpenSSL asm uses non-PIC absolute relocs (R_386_32); they fail
    # linking into Android's mandatory-PIE executables, so build it in C.
    [ "$ARCH" = i686 ] && SSL_EXTRA="$SSL_EXTRA no-asm" ;;
  *-apple-darwin*)
    TC=/opt/osxcross; export PATH="$TC/bin:$PATH"
    export MACOSX_DEPLOYMENT_TARGET=11.0
    APPLY_PATCHES=0
    case "$ARCH" in
      arm64|arm64e|aarch64) OSX_ARCH=arm64 ;;
      x86_64h)              OSX_ARCH=x86_64h ;;
      *)                    OSX_ARCH=x86_64 ;;
    esac
    CCWRAP="$(ls "$TC/bin/${OSX_ARCH}-apple-darwin"*-clang 2>/dev/null | head -n1 || true)"
    [ -n "$CCWRAP" ] || { echo "osxcross clang wrapper for $OSX_ARCH not found" >&2; exit 1; }
    HOST="$(basename "${CCWRAP%-clang}")"
    CC="$TC/bin/${HOST}-clang"; CXX="$TC/bin/${HOST}-clang++"
    AR="$TC/bin/${HOST}-ar"; RANLIB="$TC/bin/${HOST}-ranlib"
    case "$ARCH" in
      arm64|arm64e|aarch64) OPENSSL_TARGET="darwin64-arm64-cc" ;;
      *)                    OPENSSL_TARGET="darwin64-x86_64-cc" ;;
    esac ;;
  *)
    # zig (musl/gnu linux + bsd). Overlay the musl libc source fixes (lib is a+w).
    TC=/opt/zig-as-llvm
    [ -d "$ROOTDIR/patches/zig" ] && cp -R "$ROOTDIR/patches/zig/." /opt/zig/ || true
    export ZIG_TARGET="$TARGET"
    CC="$TC/bin/cc"; CXX="$TC/bin/c++"; AR="$TC/bin/ar"; RANLIB="$TC/bin/ranlib"
    case "$OS_FIELD" in
      freebsd|netbsd|openbsd)
        # The /dev/crypto engine needs <crypto/cryptodev.h>, absent from some BSD
        # zig sysroots (e.g. OpenBSD); cmake's curl doesn't need it.
        SSL_EXTRA="no-devcryptoeng"
        # OpenSSL's 32-bit x86 BSD perlasm emits .align values clang's integrated
        # assembler rejects ("alignment must be a power of 2"); build it in C.
        [ "$ARCH" = x86 ] && SSL_EXTRA="$SSL_EXTRA no-asm"
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
          mips64|mips64el) OPENSSL_TARGET="linux64-mips64" ;;
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
    esac ;;
esac

# OpenSSL 3.x guards its 64-bit RCU/refcount atomics with __atomic_is_lock_free;
# on 32-bit that's a libatomic runtime call the zig sysroots don't provide.
# BROKEN_CLANG_ATOMICS routes those ops through OpenSSL's pthread-mutex fallback.
# (Scoped to zig: NDK/llvm-mingw 32-bit targets link libatomic themselves.)
if [ "$TC" = /opt/zig-as-llvm ]; then
  case "$ARCH" in
    x86|arm|armhf|armeb|riscv32|powerpc|mips|mipsel|hexagon)
      SSL_EXTRA="$SSL_EXTRA -DBROKEN_CLANG_ATOMICS" ;;
  esac
fi

log "Building OpenSSL ($TARGET -> $OPENSSL_TARGET)"
rm -rf "$EXTRAS_DIR" "$ROOTDIR/openssl"
fetch --dir=/tmp -o openssl.tar.gz https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz
gzip -d < /tmp/openssl.tar.gz | tar -x -C "$ROOTDIR"
rm -f /tmp/openssl.tar.gz
mv "$ROOTDIR/openssl-$OPENSSL_VERSION" "$ROOTDIR/openssl"
cd "$ROOTDIR/openssl"
sed -i '/^\s*shared_cflag\s*=>\s*"-fPIC",\s*$/d' Configurations/10-main.conf
# android.patch makes X509_get_default_cert_file build a CA bundle from
# /system/etc/security/cacerts on-device (runtime-gated by $ANDROID_DATA, inert
# elsewhere). no-afalgeng below replaces the old afalg time64 source patch.
[ "$APPLY_PATCHES" = 1 ] && patch -p1 < "$ROOTDIR/patches/openssl/android.patch"
# --libdir=lib: keep a predictable extras/lib (3.x defaults some targets to lib64).
# no-afalgeng: skip the Linux afalg engine (its 32-bit time64 syscall path is the
#   only reason we used to patch OpenSSL; unneeded for cmcurl's TLS).
CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" \
  ./Configure "$OPENSSL_TARGET" no-shared no-async no-tests no-dso no-afalgeng $SSL_EXTRA \
    --prefix="$EXTRAS_DIR" --openssldir="/etc/ssl" --libdir=lib
make -j"$(nproc)"
make install_sw
log "Done -> $EXTRAS_DIR"
