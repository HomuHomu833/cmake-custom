#!/usr/bin/env bash
# Cross-build static CMake + Ninja for one target and merge them into one install
# tree. Driven by env vars so it runs identically in CI and in `docker run`.
# Run build-openssl.sh first (CMake's bundled curl links the OpenSSL it produces).
#
#   TARGET          target triple (e.g. x86_64-linux-musl, aarch64-linux-gnu,
#                   aarch64-freebsd-none)
#   CMAKE_VERSION   Kitware/CMake tag, without the leading v
#   NINJA_VERSION   ninja-build/ninja tag, without the leading v
#   ROOTDIR         checkout root (default: cwd)
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${TARGET:?set TARGET}" "${CMAKE_VERSION:?set CMAKE_VERSION}" "${NINJA_VERSION:?set NINJA_VERSION}"
ARCH="${TARGET%%-*}"
EXTRAS_DIR="$ROOTDIR/extras"
BUILD_DIR="$ROOTDIR/build"
INSTALL_DIR="$ROOTDIR/install"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Per-platform toolchain + flags. EXTRA_CMAKE carries any platform-specific -D
# flags (e.g. macOS sysroot/arch) appended to every configure.
EXTRA_CMAKE=()
case "$TARGET" in
  *-w64-mingw32)
    TC=/opt/llvm-mingw
    ZIG_CC="$TC/bin/${TARGET}-clang"; ZIG_CXX="$TC/bin/${TARGET}-clang++"
    ZIG_LD="$TC/bin/${TARGET}-ld"; ZIG_AR="$TC/bin/${TARGET}-ar"
    ZIG_RANLIB="$TC/bin/${TARGET}-ranlib"; ZIG_STRIP="$TC/bin/${TARGET}-strip"
    ZIG_OBJCOPY="$TC/bin/${TARGET}-objcopy"
    TARGET_OS=Windows
    ZIG_C_FLAGS=""
    ZIG_CXX_FLAGS=""
    # Static libwinpthread, but NOT --whole-archive: that force-pulls winpthread's
    # own version.o (a VERSIONINFO resource) which then collides with cmake's
    # CMakeVersion.rc.res ("duplicate resource"). On-demand linking is enough since
    # libuv uses Win32 threads and only libc++ pulls a few pthread symbols.
    ZIG_LINKER_FLAGS="-static-libstdc++ -static-libgcc -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic"
    # CMake compiles its own .rc resources; it defaults CMAKE_RC_COMPILER to the
    # bare `windres`, which llvm-mingw only ships target-prefixed. Point it there.
    export RC="$TC/bin/${TARGET}-windres"; export WINDRES="$RC"
    EXTRA_CMAKE=(-DCMAKE_RC_COMPILER="$RC")
    ;;
  *-linux-android*)
    # Android (bionic) via the official NDK clang, so cmake/ninja run on-device
    # (e.g. Termux). SYSTEM_NAME stays Linux so CMake uses the clang we point at
    # rather than taking over with its own NDK toolchain machinery.
    : "${NDK_VERSION:?set NDK_VERSION for the android build}"
    NDK_REVISION="${NDK_REVISION:-}"
    API="${ANDROID_PLATFORM:-24}"; [ "$TARGET" = riscv64-linux-android ] && API=35
    NDK_NAME="android-ndk-r${NDK_VERSION}${NDK_REVISION}"
    NDK_DIR="$ROOTDIR/$NDK_NAME"
    if [ ! -d "$NDK_DIR" ]; then
      log "Downloading official NDK ($NDK_NAME)"
      fetch --dir="$ROOTDIR" -o ndk.zip "https://dl.google.com/android/repository/${NDK_NAME}-linux.zip"
      unzip -qq "$ROOTDIR/ndk.zip" -d "$ROOTDIR"
      rm -f "$ROOTDIR/ndk.zip"
    fi
    TC="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
    ZIG_CC="$TC/bin/${TARGET}${API}-clang"; ZIG_CXX="${ZIG_CC}++"
    ZIG_LD="$TC/bin/ld"; ZIG_AR="$TC/bin/llvm-ar"; ZIG_RANLIB="$TC/bin/llvm-ranlib"
    ZIG_STRIP="$TC/bin/llvm-strip"; ZIG_OBJCOPY="$TC/bin/llvm-objcopy"
    TARGET_OS=Linux
    # CMake's libarchive #includes "android_lf.h" under __ANDROID__; build.sh drops
    # a stub next to archive.h, and patches/cmake is on the include path for it.
    ZIG_C_FLAGS="-I$ROOTDIR/patches/cmake"; ZIG_CXX_FLAGS="$ZIG_C_FLAGS"
    ZIG_LINKER_FLAGS="-static-libstdc++"
    ;;
  *-apple-darwin*)
    # macOS via osxcross (cctools-port + clang wrappers carrying the SDK sysroot);
    # zig segfaults building Darwin binaries.
    TC=/opt/osxcross
    export PATH="$TC/bin:$PATH"
    case "$TARGET" in
      arm64e-*) OSX_ARCH=arm64e ;;   # distinct PAC ABI, not arm64
      arm64-*|aarch64-*) OSX_ARCH=arm64 ;;
      x86_64h-*) OSX_ARCH=x86_64h ;; # Haswell+ x86_64 slice
      x86_64-*)  OSX_ARCH=x86_64 ;;
      *) echo "Unsupported macOS arch in TARGET='$TARGET'" >&2; exit 1 ;;
    esac
    # osxcross wrappers carry the SDK's darwin version (e.g. arm64-apple-darwin24.5);
    # resolve the prefix by globbing.
    CCWRAP="$(ls "$TC/bin/${OSX_ARCH}-apple-darwin"*-clang 2>/dev/null | head -n1 || true)"
    [ -n "$CCWRAP" ] || { echo "osxcross clang wrapper for $OSX_ARCH not found" >&2; exit 1; }
    HOST="$(basename "${CCWRAP%-clang}")"
    ZIG_CC="$TC/bin/${HOST}-clang"; ZIG_CXX="$TC/bin/${HOST}-clang++"
    ZIG_LD="$TC/bin/${HOST}-ld"; ZIG_AR="$TC/bin/${HOST}-ar"
    ZIG_RANLIB="$TC/bin/${HOST}-ranlib"; ZIG_STRIP="$TC/bin/${HOST}-strip"
    ZIG_OBJCOPY=""                 # cctools ships no objcopy; nothing here needs it
    TARGET_OS=Darwin
    ZIG_C_FLAGS=""; ZIG_CXX_FLAGS=""; ZIG_LINKER_FLAGS=""
    SDKROOT="$(ls -d "$TC/SDK/MacOSX"*.sdk 2>/dev/null | head -n1 || true)"
    EXTRA_CMAKE=(-DCMAKE_OSX_ARCHITECTURES="$OSX_ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
    [ -n "$SDKROOT" ] && EXTRA_CMAKE+=(-DCMAKE_OSX_SYSROOT="$SDKROOT")
    # cctools libtool under the plain name, in case a step shells out to it.
    LIBTOOLBIN="$(ls "$TC/bin/${OSX_ARCH}-apple-darwin"*-libtool 2>/dev/null | head -n1 || true)"
    if [ -n "$LIBTOOLBIN" ]; then
      mkdir -p "$BUILD_DIR/.macos-shims"; ln -sf "$LIBTOOLBIN" "$BUILD_DIR/.macos-shims/libtool"
      export PATH="$BUILD_DIR/.macos-shims:$PATH"
    fi
    ;;
  *)
    TC=/opt/zig-as-llvm
    [ -d "$ROOTDIR/patches/zig" ] && cp -R "$ROOTDIR/patches/zig/." /opt/zig/ || true
    export ZIG_TARGET="$TARGET"
    ZIG_CC="$TC/bin/cc"; ZIG_CXX="$TC/bin/c++"; ZIG_LD="$TC/bin/ld"
    ZIG_OBJCOPY="$TC/bin/objcopy"; ZIG_AR="$TC/bin/ar"; ZIG_RANLIB="$TC/bin/ranlib"; ZIG_STRIP="$TC/bin/strip"
    case "$TARGET" in
      *-freebsd-*) TARGET_OS=FreeBSD ;;
      *-netbsd-*)  TARGET_OS=NetBSD ;;
      *-openbsd-*) TARGET_OS=OpenBSD ;;
      *)           TARGET_OS=Linux ;;
    esac
    case "$TARGET" in
      *musl*) ZIG_C_FLAGS="-static"; ZIG_LINKER_FLAGS="-static" ;;
      *gnu*)  ZIG_C_FLAGS="";        ZIG_LINKER_FLAGS="-static-libstdc++ -static-libgcc" ;;
      *)      ZIG_C_FLAGS="";        ZIG_LINKER_FLAGS="" ;;
    esac
    ZIG_CXX_FLAGS="$ZIG_C_FLAGS"
    ;;
esac

if [ -d "$INSTALL_DIR/$CMAKE_VERSION-$TARGET" ]; then
    log "CMake/Ninja already built for $TARGET"; exit 0
fi

clone_repo() {
    local repo_url="$1" branch="$2" dir="$3"
    [ -d "$dir" ] || git clone --quiet --branch "$branch" --depth 1 "$repo_url" "$dir"
}

build_project() {
    local name="$1" src_dir="$2" build_dir="$3" install_dir="$4"
    log "Configuring $name ($TARGET)"
    local cmake_flags=(
        -DCMAKE_CROSSCOMPILING=True
        -DCMAKE_BUILD_TYPE=MinSizeRel
        -DCMAKE_PREFIX_PATH="$EXTRAS_DIR"
        -DCMAKE_SYSTEM_PROCESSOR="$ARCH"
        -DCMAKE_SYSTEM_NAME="$TARGET_OS"
        -DCMAKE_C_COMPILER="$ZIG_CC"
        -DCMAKE_CXX_COMPILER="$ZIG_CXX"
        -DCMAKE_ASM_COMPILER="$ZIG_CC"
        -DCMAKE_LINKER="$ZIG_LD"
        -DCMAKE_OBJCOPY="$ZIG_OBJCOPY"
        -DCMAKE_AR="$ZIG_AR"
        -DCMAKE_RANLIB="$ZIG_RANLIB"
        -DCMAKE_STRIP="$ZIG_STRIP"
        -DCMAKE_C_FLAGS="$ZIG_C_FLAGS"
        -DCMAKE_CXX_FLAGS="$ZIG_CXX_FLAGS"
        -DCMAKE_EXE_LINKER_FLAGS="$ZIG_LINKER_FLAGS"
        -DCMAKE_INSTALL_PREFIX="$install_dir"
        -DBUILD_TESTING=OFF
        # glibc/bionic/darwin satisfy both POSIX and glibc strerror_r try-compiles;
        # force POSIX so cmcurl skips the cross-impossible disambiguating try_run.
        # (musl has only POSIX, so this is a no-op there.)
        -DHAVE_GLIBC_STRERROR_R=0
        -G Ninja
    )
    if [ "$name" = CMake ]; then
        # OpenSSL is built for every target (build-openssl.sh runs first).
        cmake_flags+=(
            -DBUILD_SHARED_LIBS=OFF
            -DHAVE_POSIX_STRERROR_R=1 -DHAVE_POSIX_STRERROR_R__TRYRUN_OUTPUT=""
            -DHAVE_POLL_FINE_EXITCODE=1
            -DKWSYS_LFS_WORKS=1 -DKWSYS_LFS_WORKS__TRYRUN_OUTPUT=""
            -DHAVE_FSETXATTR_5=1 -DHAVE_FSETXATTR_5__TRYRUN_OUTPUT=""
            -DCMAKE_USE_OPENSSL=ON
            -DCMAKE_USE_SYSTEM_CURL=OFF -DCMAKE_USE_SYSTEM_ZLIB=OFF
            -DCMAKE_USE_SYSTEM_KWIML=OFF -DCMAKE_USE_SYSTEM_LIBRHASH=OFF
            -DCMAKE_USE_SYSTEM_EXPAT=OFF -DCMAKE_USE_SYSTEM_BZIP2=OFF
            -DCMAKE_USE_SYSTEM_ZSTD=OFF -DCMAKE_USE_SYSTEM_LIBLZMA=OFF
            -DCMAKE_USE_SYSTEM_LIBARCHIVE=OFF -DCMAKE_USE_SYSTEM_JSONCPP=OFF
            -DCMAKE_USE_SYSTEM_LIBUV=OFF -DCMAKE_USE_SYSTEM_FORM=OFF
            -DCMAKE_USE_SYSTEM_CPPDAP=OFF
        )
    fi
    cmake -B "$build_dir" -S "$src_dir" "${cmake_flags[@]}" "${EXTRA_CMAKE[@]}"
    log "Building $name"
    ninja -C "$build_dir" -j"$(nproc)"
    ninja -C "$build_dir" install
}

clone_repo "https://github.com/Kitware/CMake.git" "v$CMAKE_VERSION" "$ROOTDIR/cmake-$CMAKE_VERSION"
# cmWindowsRegistry.cxx: rewrite the cm::string_view initializer the cross-clang
# rejects; then swap in our cmCurl.cxx (CA-bundle handling for the static build).
sed -i '/auto separator = cm::string_view{/,/}/c\
    cm::string_view separator;\
    if (this->RegistryFormat.start(1) == std::string::npos ||\
        this->RegistryFormat.end(1) == std::string::npos) {\
      separator = this->Separator;\
    } else {\
      separator = cm::string_view{\
        this->Expression.data() + this->RegistryFormat.start(1),\
        this->RegistryFormat.end(1) - this->RegistryFormat.start(1)\
    };\
}' "$ROOTDIR/cmake-$CMAKE_VERSION/Source/cmWindowsRegistry.cxx" || true
cp "$ROOTDIR/patches/cmake/cmCurl.cxx" "$ROOTDIR/cmake-$CMAKE_VERSION/Source/cmCurl.cxx"

# CompileFlags.cmake forces _TIME_BITS=64 on 32-bit Linux, giving cmake's own
# sources a 64-bit time_t. zig's prebuilt libc++ for 32-bit glibc is 32-bit
# time_t, so chrono's system_clock::from_time_t fails to link. Drop _TIME_BITS=64
# (keep _FILE_OFFSET_BITS=64); musl is always 64-bit time_t so it's unaffected.
sed -i 's/add_compile_definitions(_FILE_OFFSET_BITS=64 _TIME_BITS=64)/add_compile_definitions(_FILE_OFFSET_BITS=64)/' \
    "$ROOTDIR/cmake-$CMAKE_VERSION/CompileFlags.cmake" || true

case "$TARGET" in
  *-linux-android*)
    # bionic lacks pthread_setaffinity_np before API 36; disable cmlibuv's CPU
    # affinity block on Android (the three guards cover its decls, use, and the
    # cpumask entry point, which then returns UV_ENOTSUP).
    sed -i 's/#if defined(__linux__) || defined(__FreeBSD__)/#if (defined(__linux__) || defined(__FreeBSD__)) \&\& !defined(__ANDROID__)/' \
        "$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibuv/src/unix/process.c" || true
    # We build android with CMAKE_SYSTEM_NAME=Linux, so cmlibuv links the Linux
    # libs (dl rt). bionic folded librt into libc and ships no librt, so drop rt.
    sed -i 's/list(APPEND uv_libraries dl rt)/list(APPEND uv_libraries dl)/' \
        "$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibuv/CMakeLists.txt" || true
    ;;
  *-netbsd-*)
    # zig's NetBSD sysroot ships <kvm.h> but no libkvm; stub the one consumer
    # (uv_resident_set_memory) and drop the -lkvm link so cmake links.
    perl -0pi -e 's/int uv_resident_set_memory\(size_t\* rss\) \{.*?\n\}/int uv_resident_set_memory(size_t* rss) {\n  *rss = 0;\n  return UV_ENOSYS;\n}/s' \
        "$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibuv/src/unix/netbsd.c" || true
    sed -i '/^[[:space:]]*kvm[[:space:]]*$/d' \
        "$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibuv/CMakeLists.txt" || true
    ;;
esac
clone_repo "https://github.com/ninja-build/ninja.git" "v$NINJA_VERSION" "$ROOTDIR/ninja-$NINJA_VERSION"

build_project CMake "$ROOTDIR/cmake-$CMAKE_VERSION" \
    "$BUILD_DIR/cmake-$CMAKE_VERSION-$TARGET" "$BUILD_DIR/binary-cmake-$CMAKE_VERSION-$TARGET"
build_project Ninja "$ROOTDIR/ninja-$NINJA_VERSION" \
    "$BUILD_DIR/ninja-$CMAKE_VERSION-$TARGET" "$BUILD_DIR/binary-ninja-$CMAKE_VERSION-$TARGET"

log "Merging Ninja into the CMake install tree"
mkdir -p "$INSTALL_DIR/$CMAKE_VERSION-$TARGET"
for d in "$BUILD_DIR/binary-cmake-$CMAKE_VERSION-$TARGET" "$BUILD_DIR/binary-ninja-$CMAKE_VERSION-$TARGET"; do
    cp -R "$d"/. "$INSTALL_DIR/$CMAKE_VERSION-$TARGET"
done
log "Done -> $INSTALL_DIR/$CMAKE_VERSION-$TARGET"
