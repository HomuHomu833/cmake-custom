#!/usr/bin/env bash
# Cross-build static OpenSSL (default 3.6.3) for one target; CMake's curl links it.
# Driven by env vars so it runs identically in CI and in `docker run`.
#
#   PLATFORM  linux | bsd | windows | macos | android  (selects the toolchain)
#   TARGET    target triple (e.g. x86_64-linux-musl, aarch64-linux-gnu,
#             aarch64-freebsd-none, aarch64-linux-android, arm64-apple-darwin,
#             x86_64-w64-mingw32)
#   ROOTDIR   checkout root (default: cwd)
#   NDK_VERSION/NDK_REVISION  official NDK for the android clang (android only)
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${PLATFORM:?set PLATFORM}" "${TARGET:?set TARGET}"
ARCH="${TARGET%%-*}"
EXTRAS_DIR="$ROOTDIR/extras"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Unpack ARCHIVE into DEST, picking the tool from the extension.
unpack() {
  case "$1" in
    *.tar.gz|*.tgz) tar -xzf "$1" -C "$2" ;;
    *.tar.xz)       tar -xJf "$1" -C "$2" ;;
    *.tar.bz2)      tar -xjf "$1" -C "$2" ;;
    *.zip)          unzip -qq -o "$1" -d "$2" ;;
    *) echo "unpack: don't know how to unpack $1" >&2; return 1 ;;
  esac
}

# Download URL to ARCHIVE and unpack it into DEST (default: the current
# directory), re-downloading when the unpack fails. ARCHIVE is removed on the
# way out. Usage: fetch_unpack URL ARCHIVE [DEST]
#
# aria2c's own retries cannot see a truncated download. Endpoints that generate
# archives on the fly, such as codeload, stream them chunked with
# no Content-Length (aria2 logs the size as "0B/0B"), so when the far end cuts
# the stream short there is no expected size to compare against: aria2 prints
# "(OK):download completed" and exits 0 on a 600KiB truncation of a 200MiB
# archive, and the damage only surfaces further down as "gzip: stdin:
# unexpected end of file". Unpacking is the only integrity check available, so
# the retry has to wrap the download and the unpack together.
fetch_unpack() {
  local url="$1" archive="$2" dest="${3:-.}" i=0
  mkdir -p "$dest"
  while :; do
    rm -f "$archive" "$archive.aria2"
    if fetch --dir="$(dirname "$archive")" -o "$(basename "$archive")" "$url" \
       && unpack "$archive" "$dest"; then
      rm -f "$archive"
      return 0
    fi
    i=$((i + 1))
    [ "$i" -ge 5 ] && { echo "fetch_unpack: $url still incomplete after $i attempts" >&2; return 1; }
    echo "fetch_unpack: $(basename "$archive") came down incomplete, retry $i/5 in $((5 * i))s..." >&2
    sleep $((5 * i))
  done
}

OPENSSL_VERSION="${OPENSSL_VERSION:-3.6.3}"

# --- per-platform compiler + OpenSSL Configure target -----------------------
# Dispatch on PLATFORM (not the triple) so the toolchain is chosen explicitly.
# APPLY_PATCHES gates the android source patch; off for windows/macos (the cert
# bundle is a bionic on-device concern and pulls POSIX dirent code those lack).
# CC/CXX/AR/RANLIB select the toolchain, AR matters for macOS (ld64 rejects a
# GNU-format archive, so OpenSSL must use the cctools ar).
APPLY_PATCHES=1
SSL_EXTRA=""
case "$PLATFORM" in
  windows)
    TC=/opt/llvm-mingw
    CC="$TC/bin/${TARGET}-clang"; CXX="$TC/bin/${TARGET}-clang++"
    AR="$TC/bin/${TARGET}-ar"; RANLIB="$TC/bin/${TARGET}-ranlib"
    # OpenSSL's mingw build calls bare `windres`; llvm-mingw ships it prefixed.
    export RC="$TC/bin/${TARGET}-windres"; export WINDRES="$RC"
    APPLY_PATCHES=0
    case "$ARCH" in
      x86_64)  OPENSSL_TARGET="mingw64" ;;
      aarch64) OPENSSL_TARGET="mingwarm64" ;;
      i686)    OPENSSL_TARGET="mingw" ;;
      # No upstream config: supplied by patches/openssl/50-llvm-mingw.conf.
      armv7)   OPENSSL_TARGET="mingw-armv7" ;;
      arm64ec) OPENSSL_TARGET="mingw-arm64ec" ;;
      *)       echo "No OpenSSL Configure target for windows ARCH='$ARCH'" >&2; exit 1 ;;
    esac ;;
  android)
    : "${NDK_VERSION:?set NDK_VERSION for the android build}"
    NDK_REVISION="${NDK_REVISION:-}"
    API="${ANDROID_PLATFORM:-24}"; [ "$TARGET" = riscv64-linux-android ] && API=35
    NDK_NAME="android-ndk-r${NDK_VERSION}${NDK_REVISION}"; NDK_DIR="$ROOTDIR/$NDK_NAME"
    if [ ! -d "$NDK_DIR" ]; then
      log "Downloading official NDK ($NDK_NAME)"
      fetch_unpack "https://dl.google.com/android/repository/${NDK_NAME}-linux.zip" "$ROOTDIR/ndk.zip" "$ROOTDIR"
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
  macos)
    TC=/opt/osxcross; export PATH="$TC/bin:$PATH"
    export MACOSX_DEPLOYMENT_TARGET=11.0
    APPLY_PATCHES=0
    case "$ARCH" in
      arm64e)          OSX_ARCH=arm64e ;;
      arm64|aarch64)   OSX_ARCH=arm64 ;;
      x86_64h)         OSX_ARCH=x86_64h ;;
      *)               OSX_ARCH=x86_64 ;;
    esac
    CCWRAP="$(ls "$TC/bin/${OSX_ARCH}-apple-darwin"*-clang 2>/dev/null | head -n1 || true)"
    [ -n "$CCWRAP" ] || { echo "osxcross clang wrapper for $OSX_ARCH not found" >&2; exit 1; }
    HOST="$(basename "${CCWRAP%-clang}")"
    CC="$TC/bin/${HOST}-clang"; CXX="$TC/bin/${HOST}-clang++"
    AR="$TC/bin/${HOST}-ar"; RANLIB="$TC/bin/${HOST}-ranlib"
    case "$ARCH" in
      # darwin64-arm64 hardcodes -arch arm64, which would override the arm64e
      # wrapper; 51-darwin-arm64e.conf supplies an -arch arm64e variant.
      arm64e)               OPENSSL_TARGET="darwin64-arm64e" ;;
      arm64|aarch64)        OPENSSL_TARGET="darwin64-arm64-cc" ;;
      *)                    OPENSSL_TARGET="darwin64-x86_64-cc" ;;
    esac ;;
  linux)
    TC=/opt/zig-as-llvm
    [ -d "$ROOTDIR/patches/zig" ] && cp -R "$ROOTDIR/patches/zig/." /opt/zig/ || true
    export ZIG_TARGET="$TARGET"
    # ppc64le glibc: clang's IEEE-128 long double makes libc++ call
    # glibc's __*ieee128 printf entries, which arrived in 2.32.
    case "$TARGET" in powerpc64le-*-gnu*) export ZIG_TARGET="$TARGET.2.32" ;; esac
    CC="$TC/bin/cc"; CXX="$TC/bin/c++"; AR="$TC/bin/ar"; RANLIB="$TC/bin/ranlib"
    case "$ARCH" in
      aarch64)         OPENSSL_TARGET="linux-aarch64" ;;
      aarch64_be)      OPENSSL_TARGET="linux-generic64" ;;
      arm|armhf)       OPENSSL_TARGET="linux-armv4" ;;
      armeb)           OPENSSL_TARGET="linux-generic32" ;;
      loongarch32)     OPENSSL_TARGET="linux-generic32" ;;
      loongarch64)     OPENSSL_TARGET="linux64-loongarch64" ;;
      mips|mipsel)     OPENSSL_TARGET="linux-mips32" ;;
      mips64|mips64el)
       case "$TARGET" in
          *n32*) OPENSSL_TARGET="linux-mips64"; SSL_EXTRA="$SSL_EXTRA no-asm" ;;
          *)     OPENSSL_TARGET="linux64-mips64" ;;
        esac ;;
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
  bsd)
    # zig (same wrappers as linux), all BSD targets.
    TC=/opt/zig-as-llvm
    [ -d "$ROOTDIR/patches/zig" ] && cp -R "$ROOTDIR/patches/zig/." /opt/zig/ || true
    export ZIG_TARGET="$TARGET"
    case "$TARGET" in powerpc64le-*-gnu*) export ZIG_TARGET="$TARGET.2.32" ;; esac
    CC="$TC/bin/cc"; CXX="$TC/bin/c++"; AR="$TC/bin/ar"; RANLIB="$TC/bin/ranlib"
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
  *) echo "Unknown/unsupported PLATFORM='$PLATFORM'" >&2; exit 1 ;;
esac

# OpenSSL 3.x guards its 64-bit RCU/refcount atomics with __atomic_is_lock_free;
# on 32-bit that's a libatomic runtime call the zig sysroots don't provide.
# BROKEN_CLANG_ATOMICS routes those ops through OpenSSL's pthread-mutex fallback.
# (zig linux/bsd only: NDK/llvm-mingw 32-bit targets link libatomic themselves.)
case "$PLATFORM" in
  linux|bsd)
    case "$ARCH" in
      x86|arm|armhf|armeb|riscv32|powerpc|mips|mipsel|hexagon|loongarch32)
        SSL_EXTRA="$SSL_EXTRA -DBROKEN_CLANG_ATOMICS" ;;
    esac ;;
esac

log "Building OpenSSL ($TARGET -> $OPENSSL_TARGET)"
rm -rf "$EXTRAS_DIR" "$ROOTDIR/openssl"
fetch_unpack "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
  /tmp/openssl.tar.gz "$ROOTDIR"
mv "$ROOTDIR/openssl-$OPENSSL_VERSION" "$ROOTDIR/openssl"
cd "$ROOTDIR/openssl"
sed -i '/^\s*shared_cflag\s*=>\s*"-fPIC",\s*$/d' Configurations/10-main.conf
# armv7/arm64ec windows have no upstream config; OpenSSL merges every
# Configurations/*.conf, so dropping ours in defines those two targets.
cp "$ROOTDIR/patches/openssl/50-llvm-mingw.conf" Configurations/
cp "$ROOTDIR/patches/openssl/51-darwin-arm64e.conf" Configurations/
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
make -j"$(nproc)" build_libs
make install_dev
log "Done -> $EXTRAS_DIR"
