#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <Target Triple>"
    exit 1
fi

TARGET_TRIPLE="$1"
ROOT_DIR="$(pwd)"
EXTRAS_DIR="$ROOT_DIR/extras"
TOOLCHAIN="$ROOT_DIR/zig-as-llvm"
ZIG_CC="$TOOLCHAIN/bin/cc"
ZIG_CXX="$TOOLCHAIN/bin/c++"
ZIG_LD="$TOOLCHAIN/bin/ld"
ZIG_OBJCOPY="$TOOLCHAIN/bin/objcopy"
ZIG_AR="$TOOLCHAIN/bin/ar"
ZIG_RANLIB="$TOOLCHAIN/bin/ranlib"
ZIG_STRIP="$TOOLCHAIN/bin/strip"
ZIG_C_FLAGS="-fno-sanitize=all -static"
ZIG_CXX_FLAGS="$ZIG_C_FLAGS"
ZIG_LINKER_FLAGS="-static"

if [[ "$TARGET_TRIPLE" == mips64* ]]; then
  echo "MIPS 64-Bit currently has issues in building OpenSSL. Exiting."
  exit 0
fi

if [[ "$TARGET_TRIPLE" == *freebsd* || "$TARGET_TRIPLE" == *netbsd* ]]; then
    ZIG_C_FLAGS="${ZIG_C_FLAGS//-static/}"
    ZIG_CXX_FLAGS="${ZIG_CXX_FLAGS//-static/}"
    ZIG_LINKER_FLAGS="${ZIG_LINKER_FLAGS//-static/}"
fi

export ZIG_TARGET="$TARGET_TRIPLE"

rm -rf $EXTRAS_DIR $ROOT_DIR/openssl

cd $ROOT_DIR
curl -LkSs https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz | gzip -d | tar -x
mv openssl-1.1.1w openssl
cd openssl
sed -i '/^\s*shared_cflag\s*=>\s*"-fPIC",\s*$/d' Configurations/10-main.conf
patch -p1 < $ROOT_DIR/patches/openssl/fix-io_getevents-time64.patch
patch -p1 < $ROOT_DIR/patches/openssl/android.patch
case "$TARGET_TRIPLE" in
    aarch64-linux-musl)      OPENSSL_TARGET="linux-aarch64" ;;
    aarch64_be-linux-musl)   OPENSSL_TARGET="linux-generic64" ;;  # No official support, generic fallback
    arm-linux-musleabi)      OPENSSL_TARGET="linux-armv4" ;;
    arm-linux-musleabihf)    OPENSSL_TARGET="linux-armv4" ;;
    armeb-linux-musleabi)    OPENSSL_TARGET="linux-generic32" ;;
    armeb-linux-musleabihf)  OPENSSL_TARGET="linux-generic32" ;;
    loongarch64-linux-musl)  OPENSSL_TARGET="linux64-loongarch64" ;;
    mips-linux-musleabi)     OPENSSL_TARGET="linux-mips32" ;;
    mips-linux-musleabihf)   OPENSSL_TARGET="linux-mips32" ;;
    mipsel-linux-musleabi)   OPENSSL_TARGET="linux-mips32" ;;
    mipsel-linux-musleabihf) OPENSSL_TARGET="linux-mips32" ;;
    mips64-linux-muslabin32) OPENSSL_TARGET="linux64-mips64" ;;
    mips64el-linux-muslabin32) OPENSSL_TARGET="linux64-mips64" ;;
    powerpc-linux-musleabi)  OPENSSL_TARGET="linux-ppc" ;;
    powerpc-linux-musleabihf) OPENSSL_TARGET="linux-ppc" ;;
    powerpc64-linux-musl)    OPENSSL_TARGET="linux-ppc64" ;;
    powerpc64le-linux-musl)  OPENSSL_TARGET="linux-ppc64le" ;;
    riscv32-linux-musl)      OPENSSL_TARGET="linux-generic32" ;;  # No official support, generic fallback
    riscv64-linux-musl)      OPENSSL_TARGET="linux64-riscv64" ;;
    s390x-linux-musl)        OPENSSL_TARGET="linux64-s390x" ;;
    x86-linux-musl)          OPENSSL_TARGET="linux-x86" ;;
    x86_64-linux-musl)       OPENSSL_TARGET="linux-x86_64" ;;
    x86_64-linux-muslx32)    OPENSSL_TARGET="linux-x32" ;;
esac
CC=$ZIG_CC CXX=$ZIG_CXX RANLIB=$ZIG_RANLIB ./Configure "$OPENSSL_TARGET" no-shared no-async no-tests no-dso --prefix="$EXTRAS_DIR" --openssldir="/etc/ssl"
make -j$(nproc)
make install_sw
