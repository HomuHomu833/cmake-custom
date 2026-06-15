# Prebuilt builder image for cmake-custom: bakes zig + the zig-as-llvm wrappers,
# llvm-mingw (windows), and the host tools needed to cross-build CMake / Ninja /
# OpenSSL, so CI only pulls.
#
# Build scripts are NOT copied in — they're bind-mounted from the checkout at run
# time, so editing scripts/ needs no rebuild.
#
#   docker run --rm -v "$PWD:/work" -w /work \
#     -e TARGET=x86_64-linux-musl -e CMAKE_VERSION=4.1.2 -e NINJA_VERSION=1.12.1 \
#     ghcr.io/<owner>/cmake-builder \
#     bash -c 'scripts/build-openssl.sh && scripts/build.sh'
FROM ubuntu:24.04

ARG ZIG_VERSION=0.17.0-dev.857+2b2b85c5f
ARG LLVM_MINGW_VERSION=20260505
ARG MACOS_SDK_VERSION=15.5
ARG REPO_OWNER=HomuHomu833

ENV DEBIAN_FRONTEND=noninteractive
# build-essential/cmake/ninja: host tools to bootstrap the CMake/Ninja cross build.
# perl: OpenSSL's Configure. patch: source fixups. aria2/xz/git: fetch + unpack.
# p7zip-full: 7z archives for the windows builds.
# clang/lld + lib*-dev/cpio/bzip2: build osxcross (cctools-port) at image time.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates aria2 xz-utils unzip p7zip-full git make cmake ninja-build \
        build-essential clang lld perl patch file python3 \
        libssl-dev libxml2-dev liblzma-dev uuid-dev zlib1g-dev cpio bzip2 \
    && rm -rf /var/lib/apt/lists/*

# fetch: aria2c with retries (transient GitHub 5xx). build scripts can reuse it.
RUN printf '%s\n' '#!/bin/sh' \
    'i=0; until aria2c --console-log-level=error --check-certificate=false --max-tries=5 --retry-wait=2 --connect-timeout=15 "$@"; do' \
    '  i=$((i+1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; exit 1; }' \
    '  echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2' \
    'done' > /usr/local/bin/fetch && chmod +x /usr/local/bin/fetch

# zig: cross C/C++ toolchain for the musl/gnu/bsd targets.
RUN arch="$(uname -m)"; \
    case "$arch" in \
        x86_64)        zig_arch="x86_64" ;; \
        aarch64)       zig_arch="aarch64" ;; \
        armv7l|armv8l) zig_arch="arm" ;; \
        riscv64)       zig_arch="riscv64" ;; \
        ppc64le)       zig_arch="powerpc64le" ;; \
        i686|i386)     zig_arch="x86" ;; \
        loongarch64)   zig_arch="loongarch64" ;; \
        s390x)         zig_arch="s390x" ;; \
        *) echo "WARNING: unsupported zig host arch '$arch'; skipping zig and zig-as-llvm"; touch /opt/.no-zig ;; \
    esac; \
    if [ ! -f /opt/.no-zig ]; then \
        case "$ZIG_VERSION" in \
            *dev*) zig_base="https://ziglang.org/builds" ;;        \
            *)     zig_base="https://ziglang.org/download/${ZIG_VERSION}" ;; \
        esac; \
        ( i=0; until aria2c --max-tries=20 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o zig.tar.xz \
            "${zig_base}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz"; \
          do i=$((i+1)); [ "$i" -ge 5 ] && exit 1; echo "aria2c retry $i/5" >&2; sleep 2; done ) \
        && tar -xJf /tmp/zig.tar.xz -C /opt \
        && rm /tmp/zig.tar.xz \
        && mv "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}" /opt/zig \
        && chmod -R a+w /opt/zig/lib; \
    fi   # build.sh overlays patches/zig here at run time (non-root)

# zig-as-llvm: thin cc/c++/ar/strip/... wrappers around zig (keyed off $ZIG_TARGET).
RUN if [ ! -f /opt/.no-zig ]; then \
        git clone --depth 1 "https://github.com/${REPO_OWNER}/zig-as-llvm" /opt/zig-as-llvm; \
    fi

# zig on PATH so the zig-as-llvm wrappers resolve it.
ENV PATH="/opt/zig:${PATH}"

# llvm-mingw (windows targets; only x86_64 / aarch64 linux hosts can run it).
# NOT on PATH — build.sh calls it by absolute path.
RUN arch="$(uname -m)"; \
    case "$arch" in \
        x86_64|aarch64) \
            fetch --dir=/tmp -o llvm-mingw.tar.xz \
                "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${arch}.tar.xz" \
            && tar -xJf /tmp/llvm-mingw.tar.xz -C /opt \
            && rm /tmp/llvm-mingw.tar.xz \
            && mv "/opt/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${arch}" /opt/llvm-mingw ;; \
        *) echo "WARNING: llvm-mingw does not support host arch '$arch'; Windows cross-builds will be unavailable" ;; \
    esac

# osxcross: macOS cross toolchain (cctools-port + clang wrappers) with the macOS
# SDK baked into /opt/osxcross/SDK; zig segfaults building Darwin binaries.
ARG OSXCROSS_REF=master
RUN git clone https://github.com/tpoechtrager/osxcross /tmp/osxcross \
    && git -C /tmp/osxcross checkout "$OSXCROSS_REF" \
    && fetch \
        --dir=/tmp/osxcross/tarballs -o "MacOSX${MACOS_SDK_VERSION}.sdk.tar.xz" \
        "https://github.com/joseluisq/macosx-sdks/releases/download/${MACOS_SDK_VERSION}/MacOSX${MACOS_SDK_VERSION}.sdk.tar.xz" \
    && cd /tmp/osxcross \
    && UNATTENDED=1 ENABLE_ARCHS="x86_64 x86_64h arm64 arm64e" OSX_VERSION_MIN=11.0 \
       TARGET_DIR=/opt/osxcross ./build.sh \
    && cd / \
    && rm -rf /tmp/osxcross

# Android (bionic): the official NDK is downloaded by build.sh at run time.

WORKDIR /work
