#!/usr/bin/env bash
# Cross-build static CMake + Ninja for one target and merge them into one install
# tree. Driven by env vars so it runs identically in CI and in `docker run`.
# Run build-openssl.sh first (CMake's bundled curl links the OpenSSL it produces).
#
#   PLATFORM        linux | bsd | windows | macos | android  (selects the toolchain)
#   TARGET          target triple (e.g. x86_64-linux-musl, aarch64-linux-gnu,
#                   aarch64-freebsd-none)
#   CMAKE_VERSION   Kitware/CMake tag, without the leading v
#   NINJA_VERSION   ninja-build/ninja tag, without the leading v
#   ROOTDIR         checkout root (default: cwd)
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${PLATFORM:?set PLATFORM}" "${TARGET:?set TARGET}" "${CMAKE_VERSION:?set CMAKE_VERSION}" "${NINJA_VERSION:?set NINJA_VERSION}"
ARCH="${TARGET%%-*}"
EXTRAS_DIR="$ROOTDIR/extras"
BUILD_DIR="$ROOTDIR/build"
INSTALL_DIR="$ROOTDIR/install"
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

# Per-platform toolchain + flags, dispatched on PLATFORM (not the triple) so the
# toolchain is chosen explicitly. EXTRA_CMAKE carries any platform-specific -D
# flags (e.g. macOS sysroot/arch) appended to every configure.
EXTRA_CMAKE=()
case "$PLATFORM" in
  windows)
    TC=/opt/llvm-mingw
    ZIG_CC="$TC/bin/${TARGET}-clang"; ZIG_CXX="$TC/bin/${TARGET}-clang++"
    ZIG_LD="$TC/bin/${TARGET}-ld"; ZIG_AR="$TC/bin/${TARGET}-ar"
    ZIG_RANLIB="$TC/bin/${TARGET}-ranlib"; ZIG_STRIP="$TC/bin/${TARGET}-strip"
    ZIG_OBJCOPY="$TC/bin/${TARGET}-objcopy"
    TARGET_OS=Windows
    # mingw's stdlib.h and inttypes.h define llabs, imaxabs, lltoa and their
    # neighbours inline, and cmliblzma ends up with a copy in more than one
    # object. __CRT__NO_INLINE is the header's own switch for declaring them
    # instead and taking the ones in libmingwex.
    ZIG_C_FLAGS="-D__CRT__NO_INLINE"
    ZIG_CXX_FLAGS="-D__CRT__NO_INLINE"
    # arm64ec advertises x64 compatibility (_M_AMD64), so cmzstd's SIMD probe
    # takes the SSE2 branch and includes <emmintrin.h>, which the aarch64
    # backend cannot compile. ZSTD_NO_INTRINSICS is zstd's own opt-out.
    if [ "$ARCH" = arm64ec ]; then
      ZIG_C_FLAGS="$ZIG_C_FLAGS -DZSTD_NO_INTRINSICS"
      ZIG_CXX_FLAGS="$ZIG_CXX_FLAGS -DZSTD_NO_INTRINSICS"
    fi
    # Static libwinpthread, no --whole-archive (it pulls winpthread's version.o
    # VERSIONINFO, clashing with cmake's CMakeVersion.rc.res).
    # crypt32 for openssl's capi engine, which libcrypto always carries on
    # windows. cmcurl links it itself from 4.x, older trees leave it undefined.
    ZIG_LINKER_FLAGS="-static-libstdc++ -static-libgcc -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic -lcrypt32"
    # cmake's .rc build calls bare `windres`; llvm-mingw only ships it prefixed.
    export RC="$TC/bin/${TARGET}-windres"; export WINDRES="$RC"
    EXTRA_CMAKE=(-DCMAKE_RC_COMPILER="$RC")
    ;;
  android)
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
      fetch_unpack "https://dl.google.com/android/repository/${NDK_NAME}-linux.zip" "$ROOTDIR/ndk.zip" "$ROOTDIR"
    fi
    TC="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
    ZIG_CC="$TC/bin/${TARGET}${API}-clang"; ZIG_CXX="${ZIG_CC}++"
    ZIG_LD="$TC/bin/ld"; ZIG_AR="$TC/bin/llvm-ar"; ZIG_RANLIB="$TC/bin/llvm-ranlib"
    ZIG_STRIP="$TC/bin/llvm-strip"; ZIG_OBJCOPY="$TC/bin/llvm-objcopy"
    TARGET_OS=Linux
    # -I patches/cmake: stub "android_lf.h" libarchive includes under __ANDROID__.
    ZIG_C_FLAGS="-I$ROOTDIR/patches/cmake -include $ROOTDIR/patches/cmake/android_compat.h -static"
    ZIG_CXX_FLAGS="$ZIG_C_FLAGS"
    ZIG_LINKER_FLAGS="-static -Wl,-z,max-page-size=16384"

    # arm/arm64 executables need an 8-word-aligned PT_TLS to clear bionic's TCB
    # slots, or the loader aborts with "executable's TLS segment is underaligned".
    # crtbegin only supplies that from API 29, so link our own copy into every
    # tool. Preprocessor-guarded, hence built unconditionally.
    log "Building bionic TLS alignment stub"
    mkdir -p "$BUILD_DIR"
    "$ZIG_CC" -c "$ROOTDIR/patches/cmake/bionic_tls_align.S" -o "$BUILD_DIR/bionic_tls_align.o"
    ZIG_LINKER_FLAGS="$ZIG_LINKER_FLAGS $BUILD_DIR/bionic_tls_align.o"

    ;;
  macos)
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
  linux)
    # Linux (musl/gnu) via zig-as-llvm. SYSTEM_NAME=Linux.
    TC=/opt/zig-as-llvm
    [ -d "$ROOTDIR/patches/zig" ] && cp -R "$ROOTDIR/patches/zig/." /opt/zig/ || true
    export ZIG_TARGET="$TARGET"
    # ppc64le glibc: clang's IEEE-128 long double makes libc++ call
    # glibc's __*ieee128 printf entries, which arrived in 2.32.
    case "$TARGET" in powerpc64le-*-gnu*) export ZIG_TARGET="$TARGET.2.32" ;; esac
    ZIG_CC="$TC/bin/cc"; ZIG_CXX="$TC/bin/c++"; ZIG_LD="$TC/bin/ld"
    ZIG_OBJCOPY="$TC/bin/objcopy"; ZIG_AR="$TC/bin/ar"; ZIG_RANLIB="$TC/bin/ranlib"; ZIG_STRIP="$TC/bin/strip"
    TARGET_OS=Linux
    # musl links fully static; glibc links static libstdc++/libgcc only.
    case "$TARGET" in
      *musl*) ZIG_C_FLAGS="-static"; ZIG_LINKER_FLAGS="-static" ;;
      *gnu*)  ZIG_C_FLAGS="";        ZIG_LINKER_FLAGS="-static-libstdc++ -static-libgcc" ;;
      *)      ZIG_C_FLAGS="";        ZIG_LINKER_FLAGS="" ;;
    esac
    # mips64 N64: clang warns "-fno-PIC ignored ... with -mabicalls and the N64
    # ABI", and cmake fails a feature probe on any warning in its output, so
    # every C++ check reports "no" and the build stops at "does not support
    # C++11". Silence just that diagnostic.
    case "$TARGET" in mips64*) ZIG_C_FLAGS="$ZIG_C_FLAGS -Wno-option-ignored" ;; esac
    ZIG_CXX_FLAGS="$ZIG_C_FLAGS"
    ;;
  bsd)
    TC=/opt/zig-as-llvm
    [ -d "$ROOTDIR/patches/zig" ] && cp -R "$ROOTDIR/patches/zig/." /opt/zig/ || true
    export ZIG_TARGET="$TARGET"
    # ppc64le glibc: clang's IEEE-128 long double makes libc++ call
    # glibc's __*ieee128 printf entries, which arrived in 2.32.
    case "$TARGET" in powerpc64le-*-gnu*) export ZIG_TARGET="$TARGET.2.32" ;; esac
    ZIG_CC="$TC/bin/cc"; ZIG_CXX="$TC/bin/c++"; ZIG_LD="$TC/bin/ld"
    ZIG_OBJCOPY="$TC/bin/objcopy"; ZIG_AR="$TC/bin/ar"; ZIG_RANLIB="$TC/bin/ranlib"; ZIG_STRIP="$TC/bin/strip"
    case "$(echo "$TARGET" | cut -d- -f2)" in
      freebsd) TARGET_OS=FreeBSD ;;
      netbsd)  TARGET_OS=NetBSD ;;
      openbsd) TARGET_OS=OpenBSD ;;
      *)       TARGET_OS=Generic ;;
    esac
    ZIG_C_FLAGS=""; ZIG_CXX_FLAGS=""; ZIG_LINKER_FLAGS=""
    ;;
  *) echo "Unknown/unsupported PLATFORM='$PLATFORM'" >&2; exit 1 ;;
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
        -DCMAKE_C_COMPILER_AR="$ZIG_AR"
        -DCMAKE_CXX_COMPILER_AR="$ZIG_AR"
        -DCMAKE_C_COMPILER_RANLIB="$ZIG_RANLIB"
        -DCMAKE_CXX_COMPILER_RANLIB="$ZIG_RANLIB"
        -DCMAKE_STRIP="$ZIG_STRIP"
        -DCMAKE_C_FLAGS="$ZIG_C_FLAGS -Wno-unused-command-line-argument"
        -DCMAKE_CXX_FLAGS="$ZIG_CXX_FLAGS -Wno-unused-command-line-argument"
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
            -DHAVE_FSETXATTR_6=1 -DHAVE_FSETXATTR_6__TRYRUN_OUTPUT=""
            -DCMAKE_USE_OPENSSL=ON
            -DCMAKE_USE_SYSTEM_CURL=OFF -DCMAKE_USE_SYSTEM_ZLIB=OFF
            -DCMAKE_USE_SYSTEM_KWIML=OFF -DCMAKE_USE_SYSTEM_LIBRHASH=OFF
            -DCMAKE_USE_SYSTEM_EXPAT=OFF -DCMAKE_USE_SYSTEM_BZIP2=OFF
            -DCMAKE_USE_SYSTEM_ZSTD=OFF -DCMAKE_USE_SYSTEM_LIBLZMA=OFF
            -DCMAKE_USE_SYSTEM_LIBARCHIVE=OFF -DCMAKE_USE_SYSTEM_JSONCPP=OFF
            -DCMAKE_USE_SYSTEM_LIBUV=OFF -DCMAKE_USE_SYSTEM_FORM=OFF
            -DCMAKE_USE_SYSTEM_CPPDAP=OFF
        )
        case "$PLATFORM" in
          android)
            # lchmod: in libc.a so the link test finds it, declared only from
            # API 36. memmove the other way round, check_symbol_exists misses
            # it and expat #errors without it.
            cmake_flags+=(-DHAVE_FCHDIR=ON -DHAVE_PIPE=ON -DHAVE_POSIX_SPAWNP=ON -DHAVE_FUTIMESAT=OFF -DHAVE_LUTIMES=OFF -DHAVE_NL_LANGINFO=OFF -DHAVE_LCHMOD=OFF -DHAVE_MEMMOVE=ON) ;;
          windows)
            # curl's windows probe passes int* where ioctlsocket wants u_long*,
            # an error since clang 15, so it loses to the amiga one and
            # nonblock.c calls IoctlSocket. A defined value skips the probe.
            cmake_flags+=(-DHAVE_IOCTLSOCKET_FIONBIO=1) ;;
        esac
    fi
    # cmake only prints "- no" when a feature probe fails, and treats any warning
    # in the probe output as a failure too, so dump the logs that hold the real
    # compiler/linker error before giving up.
    if ! cmake -B "$build_dir" -S "$src_dir" "${cmake_flags[@]}" "${EXTRA_CMAKE[@]}"; then
      for l in "$build_dir/CMakeFiles/CMakeError.log" "$build_dir/CMakeFiles/CMakeConfigureLog.yaml"; do
        [ -f "$l" ] || continue
        log "--- $l ---"
        tail -n 200 "$l"
      done
      exit 1
    fi
    log "Building $name"
    ninja -C "$build_dir" -j"$(nproc)"
    ninja -C "$build_dir" install
}

clone_repo "https://github.com/Kitware/CMake.git" "v$CMAKE_VERSION" "$ROOTDIR/cmake-$CMAKE_VERSION"
# cmWindowsRegistry.cxx: rewrite the cm::string_view initializer the cross-clang
# rejects. The file arrived in 3.24, so this is a no-op on anything older.
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
# cmCurl.cxx: find termux's cert.pem at $HOME/../usr/etc/tls, cmake having no
# $PREFIX. Edits rather than a copy of the file, which pinned one generation.
# GetEnv and FileExists kept these signatures since well before 3.6. The guard
# is the one cmake puts on the bundle search itself, which from 3.10 is also
# what pulls in cmSystemTools.h.
sed -i '0,/^  std::string e;$/s@^  std::string e;$@  std::string e;\n#if !defined(CMAKE_USE_SYSTEM_CURL) \&\& !defined(_WIN32) \&\& !defined(__APPLE__) \&\& !defined(CURL_CA_BUNDLE) \&\& !defined(CURL_CA_PATH)\n  std::string termux_ca;\n  if (cmSystemTools::GetEnv("HOME", termux_ca)) {\n    termux_ca += "/../usr/etc/tls/cert.pem";\n  }\n#endif@' \
    "$ROOTDIR/cmake-$CMAKE_VERSION/Source/cmCurl.cxx" || true
# Ahead of the Fedora bundle so an explicit cafile and SSL_CERT_* still win,
# and inside its guard, already off for windows, apple and a system curl.
sed -i 's@^#\( *\)define CMAKE_CAFILE_FEDORA@  else if (!termux_ca.empty() \&\& cmSystemTools::FileExists(termux_ca, true)) {\n    ::CURLcode res =\n      ::curl_easy_setopt(curl, CURLOPT_CAINFO, termux_ca.c_str());\n    check_curl_result(res, "Unable to set TLS/SSL Verify CAINFO: ");\n  }\n#\1define CMAKE_CAFILE_FEDORA@' \
    "$ROOTDIR/cmake-$CMAKE_VERSION/Source/cmCurl.cxx" || true

# curl up to 7.49 dumps certificate details through X509 and EVP_PKEY, opaque
# since openssl 1.1. The one call is behind CURLOPT_CERTINFO, which nothing in
# cmake sets, so compile it out. SessionHandle became Curl_easy in 7.50, so
# the anchors reach only the old trees.
_ossl="$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmcurl/lib/vtls/openssl.c"
if [ -f "$_ossl" ]; then
  sed -i 's@^static void pubkey_show(struct SessionHandle \*data,@#if 0 /* certinfo dump, reads openssl 1.0 struct internals */\n&@' "$_ossl" || true
  sed -i 's@^static CURLcode pkp_pin_peer_pubkey(X509\* cert, const char \*pinnedpubkey)@#endif\n&@' "$_ossl" || true
  sed -i 's@(void)get_cert_chain(conn, connssl);@(void)0; /* certinfo dump disabled */@' "$_ossl" || true
fi

# Any warning at all in a C++ feature probe counts as the feature missing, and
# cross targets warn about things the probe has nothing to do with: arm64e
# objects the linker calls an ABI mismatch, loongarch's unsettled lp64f name.
# Upstream carries the ld one and a growing list of the same shape.
sed -i 's@^.*-Winvalid-command-line-argument.*$@&\n    # Filter out ld warnings.\n    string(REGEX REPLACE "[^\\n]*ld: warning: [^\\n]*" "" check_output "${check_output}")\n    # Filter out the target ABI names clang has yet to settle on.\n    string(REGEX REPLACE "[^\\n]*warning: .[^\\n]*. has not been standardized[^\\n]*" "" check_output "${check_output}")@' \
    "$ROOTDIR/cmake-$CMAKE_VERSION/Source/Checks/cm_cxx_features.cmake" 2>/dev/null || true

# std::set calls its comparator on a const reference and ctest's is not const
# here. Only a recent libc++ refuses it, hence zig and not the NDK's older
# copy. Upstream made it const.
sed -i 's@^\(  bool operator()(std::string const& l, std::string const& r)\)$@\1 const@' \
    "$ROOTDIR/cmake-$CMAKE_VERSION/Source/CTest/cmCTestBuildHandler.cxx" || true

# libarchive before 3.17 keeps EVP_CIPHER_CTX, HMAC_CTX and six EVP_MD_CTX by
# value, opaque since openssl 1.1. Upstream moved them to pointers. Every
# anchor names the by-value spelling, so the pointer form sees no match.
_la="$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibarchive/libarchive"
if [ -f "$_la/archive_cryptor_private.h" ]; then
  sed -i 's@^\(\s*\)EVP_CIPHER_CTX\(\s*\)ctx;@\1EVP_CIPHER_CTX\2*ctx;@' "$_la/archive_cryptor_private.h" || true
  sed -i 's@^\(\s*\)EVP_CIPHER_CTX_init(&ctx->ctx);@\1ctx->ctx = EVP_CIPHER_CTX_new();\n\1if (ctx->ctx == NULL)\n\1\treturn -1;@' "$_la/archive_cryptor.c" || true
  sed -i 's@EVP_EncryptInit_ex(&ctx->ctx,@EVP_EncryptInit_ex(ctx->ctx,@;s@EVP_EncryptUpdate(&ctx->ctx,@EVP_EncryptUpdate(ctx->ctx,@' "$_la/archive_cryptor.c" || true
  sed -i 's@^\(\s*\)EVP_CIPHER_CTX_cleanup(&ctx->ctx);@\1EVP_CIPHER_CTX_free(ctx->ctx);\n\1ctx->ctx = NULL;@' "$_la/archive_cryptor.c" || true
  # HMAC_Init lost its short form in 1.1 as well, hence _ex with a NULL engine.
  sed -i 's@^typedef\(\s*\)HMAC_CTX \(archive_hmac_sha1_ctx\);@typedef\1HMAC_CTX* \2;@' "$_la/archive_hmac_private.h" || true
  sed -i 's@^\(\s*\)HMAC_CTX_init(ctx);@\1if ((*ctx = HMAC_CTX_new()) == NULL)\n\1\treturn -1;@' "$_la/archive_hmac.c" || true
  sed -i 's@HMAC_Init(ctx,\(.*\)EVP_sha1());@HMAC_Init_ex(*ctx,\1EVP_sha1(), NULL);@' "$_la/archive_hmac.c" || true
  sed -i 's@HMAC_Update(ctx,@HMAC_Update(*ctx,@;s@HMAC_Final(ctx,@HMAC_Final(*ctx,@' "$_la/archive_hmac.c" || true
  # Two lines at once: the other backends clean up with the same memset.
  sed -i '/HMAC_CTX_cleanup(ctx);/{N;s@^\(\s*\)HMAC_CTX_cleanup(ctx);\n\s*memset(ctx, 0, sizeof(\*ctx));@\1HMAC_CTX_free(*ctx);\n\1*ctx = NULL;@}' "$_la/archive_hmac.c" || true
  sed -i 's@^typedef EVP_MD_CTX \(archive_[a-z0-9_]*_ctx\);@typedef EVP_MD_CTX* \1;@' "$_la/archive_digest_private.h" || true
  sed -i 's@^\(\s*\)EVP_DigestInit(ctx, \(EVP_[a-z0-9]*()\));@\1if ((*ctx = EVP_MD_CTX_new()) == NULL)\n\1  return (ARCHIVE_FAILED);\n\1EVP_DigestInit(*ctx, \2);@' "$_la/archive_digest.c" || true
  sed -i 's@EVP_DigestUpdate(ctx,@EVP_DigestUpdate(*ctx,@' "$_la/archive_digest.c" || true
  # The empty-context guard read the struct, so it becomes a null check.
  sed -i 's@^\(\s*\)if (ctx->digest)$@\1if (*ctx == NULL)\n\1  return (ARCHIVE_OK);@' "$_la/archive_digest.c" || true
  sed -i 's@^\(\s*\)EVP_DigestFinal(ctx, md, NULL);@\1EVP_DigestFinal(*ctx, md, NULL);\n\1EVP_MD_CTX_free(*ctx);\n\1*ctx = NULL;@' "$_la/archive_digest.c" || true
fi
# That libarchive also pins windows to XP, and llvm-mingw's headers reject the
# pair. Move it to 7, the oldest of the versions newer cmake still offers.
sed -i -e 's@SET(NTDDI_VERSION 0x05010000)@SET(NTDDI_VERSION 0x06010000)@' \
       -e 's@SET(_WIN32_WINNT 0x0501)@SET(_WIN32_WINNT 0x0601)@' \
       -e 's@SET(WINVER 0x0501)@SET(WINVER 0x0601)@' \
    "$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibarchive/CMakeLists.txt" || true

# It also names its own fallback arc4random_buf, which bionic has declared
# since API 21. Upstream renamed it la_arc4random_buf; the define carries that
# to the call and the definition, both under the same guard.
sed -i 's@^static void arc4random_buf(void \*, size_t);@static void la_arc4random_buf(void *, size_t);\n#define arc4random_buf la_arc4random_buf@' \
    "$_la/archive_random.c" 2>/dev/null || true

# cmake forces _TIME_BITS=64 on 32-bit Linux, but zig's 32-bit-glibc libc++ is
# 32-bit time_t -> chrono::from_time_t won't link. Drop it (musl is always 64-bit).
sed -i 's/add_compile_definitions(_FILE_OFFSET_BITS=64 _TIME_BITS=64)/add_compile_definitions(_FILE_OFFSET_BITS=64)/' \
    "$ROOTDIR/cmake-$CMAKE_VERSION/CompileFlags.cmake" || true

# liblzma picks its ctz by _M_X64, which clang defines for every windows target,
# then calls the _BitScanForward64 only MSVC declares. Upstream xz now asks for
# the compiler instead. Ahead of the _M_X64 rewrite below, which would hide it.
sed -i 's@^#\([[:space:]]*\)if defined(_M_X64) // MSVC or Intel C compiler on Windows$@#\1if defined(_MSC_VER) || defined(__INTEL_COMPILER)@' \
    "$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmliblzma/liblzma/common/memcmplen.h" 2>/dev/null || true

# arm64ec defines __x86_64__/_M_X64, so cmake's bundled libraries take their x86
# branches on an ARM backend: cmzstd's cpuid asm and .p2align hints (the latter
# crashes LLVM, llvm/llvm-project#122707), cmliblzma's x86-64 range decoder asm.
# Require a non-ARM target too; no-op on real x86.
_notarm='!defined(__aarch64__) \&\& !defined(_M_ARM64) \&\& !defined(_M_ARM64EC) \&\& !defined(__arm64ec__)'
grep -rl 'defined(__x86_64__)\|defined(_M_X64)' \
    "$ROOTDIR/cmake-$CMAKE_VERSION/Utilities" 2>/dev/null | while read -r _f; do
  sed -i -e "s@defined(__x86_64__)@(defined(__x86_64__) \&\& $_notarm)@g" \
         -e "s@defined(_M_X64)@(defined(_M_X64) \&\& $_notarm)@g" "$_f"
done

# cmlibuv's non-MSVC windows branch reaches straight for lock xchgb, which
# assembles nowhere but x86. __sync_fetch_and_or is what the MSVC branch beside
# it already means and every llvm-mingw target has it.
perl -0pi -e 's/(static inline char uv__atomic_exchange_set\(char volatile\* target\) \{).*?\n\}/$1\n  return __sync_fetch_and_or(target, 1);\n}/s' \
    "$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibuv/src/win/atomicops-inl.h" 2>/dev/null || true

case "$PLATFORM" in
  android)
    # pthread_setaffinity_np is bionic API 36+; gate off cmlibuv's affinity block
    # (3 __linux__||__FreeBSD__ guards: its decls, use, and cpumask entry).
    sed -i 's/#if defined(__linux__) || defined(__FreeBSD__)/#if (defined(__linux__) || defined(__FreeBSD__)) \&\& !defined(__ANDROID__)/' \
        "$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibuv/src/unix/process.c" || true
    # cmake asks the same of pthread_getaffinity_np from 3.18. Upstream spells
    # the android carve-out into this guard itself later on.
    sed -i 's@^#  elif defined(__linux__) || defined(__FreeBSD__)$@#  elif (defined(__linux__) \&\& !defined(__ANDROID__)) || defined(__FreeBSD__)@' \
        "$ROOTDIR/cmake-$CMAKE_VERSION/Source/cmAffinity.cxx" 2>/dev/null || true
    # android builds as CMAKE_SYSTEM_NAME=Linux, so cmlibuv uses its Linux set:
    #  - drop rt: bionic folded librt into libc.
    #  - add pthread-fixes.c: __ANDROID__ redirects pthread_sigmask to
    #    uv__pthread_sigmask, defined only in cmlibuv's absent Android branch.
    _uvcml="$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibuv/CMakeLists.txt"
    sed -i 's/list(APPEND uv_libraries dl rt)/list(APPEND uv_libraries dl)/' "$_uvcml" || true
    # epoll.c only split out of linux-core.c in libuv 1.45, so take whichever
    # of the two this tree has, never both.
    _uvepoll=src/unix/epoll.c
    grep -q "$_uvepoll" "$_uvcml" || _uvepoll=src/unix/linux-core.c
    sed -i "s#$_uvepoll#src/unix/pthread-fixes.c\n    $_uvepoll#" "$_uvcml" || true
    # Android host: CMakeDetermineSystem.cmake reads $PREFIX/include/android/
    # api-level.h for CMAKE_SYSTEM_VERSION. PREFIX is a Termux convention, so
    # elsewhere it is unset and the unguarded file(READ) errors out. Fall back to
    # cmake's install root, and skip the read if still absent. Still upstream.
    sed -i 's#set(_ANDROID_API_LEVEL_H $ENV{PREFIX}/include/android/api-level.h)#set(_ANDROID_PREFIX "$ENV{PREFIX}")\n        if(NOT _ANDROID_PREFIX)\n          get_filename_component(_ANDROID_PREFIX "${CMAKE_ROOT}/../.." ABSOLUTE)\n        endif()\n        set(_ANDROID_API_LEVEL_H "${_ANDROID_PREFIX}/include/android/api-level.h")#' \
        "$ROOTDIR/cmake-$CMAKE_VERSION/Modules/CMakeDetermineSystem.cmake" || true
    sed -i 's#file(READ ${_ANDROID_API_LEVEL_H} _ANDROID_API_LEVEL_H_CONTENT)#if(EXISTS "${_ANDROID_API_LEVEL_H}")\n          file(READ "${_ANDROID_API_LEVEL_H}" _ANDROID_API_LEVEL_H_CONTENT)\n        endif()#' \
        "$ROOTDIR/cmake-$CMAKE_VERSION/Modules/CMakeDetermineSystem.cmake" || true
    sed -i 's#unset(_ANDROID_API_LEVEL_H)#unset(_ANDROID_PREFIX)\n        unset(_ANDROID_API_LEVEL_H)#' \
        "$ROOTDIR/cmake-$CMAKE_VERSION/Modules/CMakeDetermineSystem.cmake" || true
    ;;
  bsd)
    # None of zig's BSD sysroots carry libkvm, and the FreeBSD one has no
    # <kvm.h> either. Drop the -lkvm every BSD block asks for, and stub the one
    # consumer, uv_resident_set_memory. Older libuv reaches for it on NetBSD and
    # FreeBSD; newer trees only on NetBSD, where OpenBSD's sysctl form is used.
    _uvsrc="$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibuv/src/unix"
    sed -i '/^[[:space:]]*kvm[[:space:]]*$/d' \
        "$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibuv/CMakeLists.txt" || true
    # <sys/cpuset.h> sits in the block every BSD shares, but only FreeBSD has
    # the header and only FreeBSD reads CPU_SETSIZE out of it. Upstream gave it
    # a block of its own; the uv__accept4 anchor holds only before that.
    perl -0pi -e 's@^# include <sys/cpuset\.h>\n(# if defined\(__FreeBSD__\)\n#  define uv__accept4)@# if defined(__FreeBSD__)\n#  include <sys/cpuset.h>\n# endif\n$1@m' \
        "$_uvsrc/core.c" || true
    # A handful of sources ask for _XOPEN_SOURCE and _POSIX_C_SOURCE, which is
    # how OpenBSD is told to hide every BSD-only declaration, vasprintf among
    # them. libc++'s locale fallbacks call it, so anything reaching <iostream>
    # past one of these fails to compile. Upstream excuses OpenBSD from both.
    grep -rl '_XOPEN_SOURCE 700' "$ROOTDIR/cmake-$CMAKE_VERSION/Source" 2>/dev/null | while read -r _f; do
      sed -i -e 's@^#if !defined(_WIN32) \&\& !defined(__sun)$@#if !defined(_WIN32) \&\& !defined(__sun) \&\& !defined(__OpenBSD__)@' \
             -e 's@^#if defined(__OpenBSD__) || defined(__FreeBSD__) || defined(__NetBSD__)$@#if defined(__FreeBSD__) || defined(__NetBSD__)@' \
          "$_f"
    done
    # FreeBSD really declares sendmmsg/recvmmsg, so libuv's own layout-compatible
    # struct is a pointer mismatch rather than the missing prototype linux has.
    sed -i -e 's@\(return sendmmsg(fd, \)mmsg,@\1(struct mmsghdr*) mmsg,@' \
           -e 's@\(return recvmmsg(fd, \)mmsg,@\1(struct mmsghdr*) mmsg,@' \
        "$_uvsrc/freebsd.c" || true
    case "$(echo "$TARGET" | cut -d- -f2)" in
      netbsd|freebsd)
        _uvbsd="$_uvsrc/$(echo "$TARGET" | cut -d- -f2).c"
        sed -i '/^#include <kvm\.h>$/d' "$_uvbsd" || true
        perl -0pi -e 's/int uv_resident_set_memory\(size_t\* rss\) \{.*?\n\}/int uv_resident_set_memory(size_t* rss) {\n  *rss = 0;\n  return UV_ENOSYS;\n}/s' \
            "$_uvbsd" || true
        ;;
    esac
    # NetBSD __RENAME()s kevent() to __kevent100 and dup3() to __dup3100, which
    # zig's abilist does not carry, so cmlibuv's kqueue backend will not link.
    # Compile a small ABI-matched shim and append it to every exe link.
    if [ "$(echo "$TARGET" | cut -d- -f2)" = netbsd ]; then
      mkdir -p "$BUILD_DIR"
      "$ZIG_CC" -Os -c "$ROOTDIR/patches/cmake/netbsd_compat.c" \
          -o "$BUILD_DIR/netbsd_compat.o"
      ZIG_LINKER_FLAGS="$ZIG_LINKER_FLAGS $BUILD_DIR/netbsd_compat.o"
    fi
    ;;
esac
# libuv's copy_file_range shim took the offsets as ssize_t*, which is only the
# same as the off_t* its caller has on a 64-bit target. Upstream corrected the
# shim rather than the call.
sed -i 's@^\(\s*\)ssize_t\* off_\(in\|out\),$@\1off_t* off_\2,@' \
    "$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibuv/src/unix/linux-syscalls.h" \
    "$ROOTDIR/cmake-$CMAKE_VERSION/Utilities/cmlibuv/src/unix/linux-syscalls.c" 2>/dev/null || true

clone_repo "https://github.com/ninja-build/ninja.git" "v$NINJA_VERSION" "$ROOTDIR/ninja-$NINJA_VERSION"

# ninja gates browse mode on unistd.h existing, but mingw ships one without
# fork or pipe, so browse.cc goes in and will not compile. Upstream asks for
# the two functions instead.
sed -i -e 's@^include(CheckIncludeFileCXX)$@include(CheckIncludeFileCXX)\ninclude(CheckSymbolExists)@' \
       -e 's@check_include_file_cxx(unistd.h PLATFORM_HAS_UNISTD_HEADER)@check_symbol_exists(fork "unistd.h" HAVE_FORK)\n\tcheck_symbol_exists(pipe "unistd.h" HAVE_PIPE)@' \
       -e 's@set(${RESULT} "${PLATFORM_HAS_UNISTD_HEADER}" PARENT_SCOPE)@set(browse_supported 0)\n\tif(HAVE_FORK AND HAVE_PIPE)\n\t\tset(browse_supported 1)\n\tendif()\n\tset(${RESULT} "${browse_supported}" PARENT_SCOPE)@' \
    "$ROOTDIR/ninja-$NINJA_VERSION/CMakeLists.txt" 2>/dev/null || true

build_project CMake "$ROOTDIR/cmake-$CMAKE_VERSION" \
    "$BUILD_DIR/cmake-$CMAKE_VERSION-$TARGET" "$BUILD_DIR/binary-cmake-$CMAKE_VERSION-$TARGET"

# ninja only grew a CMakeLists.txt in 1.10, and the three oldest cmakes pair
# with 1.5.3 and 1.8.2. configure.py writes a build.ninja honouring CXX, AR,
# CFLAGS and LDFLAGS, so the image's ninja can drive the cross build. Those
# flags also carry the posix_spawn shim ninja needs on android.
if [ -f "$ROOTDIR/ninja-$NINJA_VERSION/CMakeLists.txt" ]; then
    build_project Ninja "$ROOTDIR/ninja-$NINJA_VERSION" \
        "$BUILD_DIR/ninja-$CMAKE_VERSION-$TARGET" "$BUILD_DIR/binary-ninja-$CMAKE_VERSION-$TARGET"
else
    case "$PLATFORM" in
      macos)   _njp=darwin ;;
      windows) _njp=mingw ;;
      bsd)     case "$TARGET" in
                 *openbsd*) _njp=openbsd ;;
                 *netbsd*)  _njp=netbsd ;;
                 *)         _njp=freebsd ;;
               esac ;;
      *)       _njp=linux ;;
    esac
    # 1.5.3's configure.py spells one except clause the python 2 way and the
    # image has 3.12. 1.8.2 is already python 3, so this finds nothing there.
    sed -i 's@except \([A-Za-z_.]*\), \([a-z][a-z]*\):@except \1 as \2:@' \
        "$ROOTDIR/ninja-$NINJA_VERSION/configure.py" || true
    # Both reach for getloadavg on anything unix and bionic has none. Upstream
    # reads sysinfo() instead; same branch, ahead of the fallback.
    sed -i '/^#else$/{N;s@^#else\ndouble GetLoadAverage() {@#elif defined(__BIONIC__)\n#include <sys/sysinfo.h>\ndouble GetLoadAverage() {\n  struct sysinfo si;\n  if (sysinfo(\&si) != 0)\n    return -0.0f;\n  return 1.0 / (1 << SI_LOAD_SHIFT) * si.loads[0];\n}\n#else\ndouble GetLoadAverage() {@}' \
        "$ROOTDIR/ninja-$NINJA_VERSION/src/util.cc" || true
    log "Configuring Ninja $NINJA_VERSION ($TARGET) with configure.py, platform $_njp"
    (
      cd "$ROOTDIR/ninja-$NINJA_VERSION"
      # configure.py passes no -std, so clang picks gnu++17 and this ninja
      # loses auto_ptr and mem_fun. C++11 still has both; the two macros cover
      # anything that pulls the standard back up.
      CXX="$ZIG_CXX" AR="$ZIG_AR" LDFLAGS="$ZIG_LINKER_FLAGS" \
      CFLAGS="$ZIG_CXX_FLAGS -std=c++11 -D_LIBCPP_ENABLE_CXX17_REMOVED_AUTO_PTR -D_LIBCPP_ENABLE_CXX17_REMOVED_BINDERS" \
        python3 configure.py --platform="$_njp" --host=linux
      ninja -j"$(nproc)"
    )
    _njbin="$BUILD_DIR/binary-ninja-$CMAKE_VERSION-$TARGET/bin"
    mkdir -p "$_njbin"
    _njgot=0
    for _n in ninja ninja.exe; do
      if [ -f "$ROOTDIR/ninja-$NINJA_VERSION/$_n" ]; then
        cp "$ROOTDIR/ninja-$NINJA_VERSION/$_n" "$_njbin/"; _njgot=1
      fi
    done
    [ "$_njgot" = 1 ] || { echo "configure.py produced no ninja binary" >&2; exit 1; }
    log "Done -> $_njbin"
fi

log "Merging Ninja into the CMake install tree"
mkdir -p "$INSTALL_DIR/$CMAKE_VERSION-$TARGET"
for d in "$BUILD_DIR/binary-cmake-$CMAKE_VERSION-$TARGET" "$BUILD_DIR/binary-ninja-$CMAKE_VERSION-$TARGET"; do
    cp -R "$d"/. "$INSTALL_DIR/$CMAKE_VERSION-$TARGET"
done
log "Done -> $INSTALL_DIR/$CMAKE_VERSION-$TARGET"
