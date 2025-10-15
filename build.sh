#!/bin/bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <CMake Version> <Ninja Version> <Target Triple> <Target Architecture> <Target Operating System>"
    exit 1
fi

CMAKE_VER="$1"
NINJA_VER="$2"
TARGET_TRIPLE="$3"
TARGET_ARCH="$4"
TARGET_OS="$5"
ROOT_DIR="$(pwd)"
EXTRAS_DIR="$ROOT_DIR/extras"
BUILD_DIR="$ROOT_DIR/build"
INSTALL_DIR="$ROOT_DIR/install"
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

if [[ "$TARGET_TRIPLE" == *freebsd* || "$TARGET_TRIPLE" == *netbsd* ]]; then
    ZIG_C_FLAGS="${ZIG_C_FLAGS//-static/}"
    ZIG_CXX_FLAGS="${ZIG_CXX_FLAGS//-static/}"
    ZIG_LINKER_FLAGS="${ZIG_LINKER_FLAGS//-static/}"
fi

export ZIG_TARGET="$TARGET_TRIPLE"

if [ -d "$INSTALL_DIR/$CMAKE_VER-$TARGET_TRIPLE" ]; then
    echo "CMake and Ninja already built for $TARGET_TRIPLE. Exiting."
    exit 0
fi

clone_repo() {
    local repo_url="$1"
    local branch="$2"
    local dir="$3"

    if [ ! -d "$dir" ]; then
        echo "Cloning $dir..."
        git clone --quiet --branch "$branch" --depth 1 "$repo_url" "$dir"
    else
        echo "$dir already exists."
    fi
}

build_project() {
    local name="$1"
    local src_dir="$2"
    local build_dir="$3"
    local install_dir="$4"

    echo "Configuring $name..."

    local cmake_flags=(
        -DCMAKE_CROSSCOMPILING=True
        -DCMAKE_BUILD_TYPE=MinSizeRel
        -DCMAKE_PREFIX_PATH="$EXTRAS_DIR"
        -DCMAKE_SYSTEM_PROCESSOR="$TARGET_ARCH"
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
        -G Ninja
    )

    if [[ "$name" == "CMake" ]]; then
        if [[ "$TARGET_TRIPLE" == mips64* ]]; then
            openssl_flag="-DCMAKE_USE_OPENSSL=OFF"
        else
            openssl_flag="-DCMAKE_USE_OPENSSL=ON"
        fi

        cmake_flags+=(
            -DBUILD_SHARED_LIBS=OFF
            -DHAVE_POSIX_STRERROR_R=1
            -DHAVE_POSIX_STRERROR_R__TRYRUN_OUTPUT=""
            -DHAVE_POLL_FINE_EXITCODE=1
            -DKWSYS_LFS_WORKS=1
            -DKWSYS_LFS_WORKS__TRYRUN_OUTPUT=""
            -DHAVE_FSETXATTR_5=1
            -DHAVE_FSETXATTR_5__TRYRUN_OUTPUT=""
            "$openssl_flag"
            -DCMAKE_USE_SYSTEM_CURL=OFF
            -DCMAKE_USE_SYSTEM_ZLIB=OFF
            -DCMAKE_USE_SYSTEM_KWIML=OFF
            -DCMAKE_USE_SYSTEM_LIBRHASH=OFF
            -DCMAKE_USE_SYSTEM_EXPAT=OFF
            -DCMAKE_USE_SYSTEM_BZIP2=OFF
            -DCMAKE_USE_SYSTEM_ZSTD=OFF
            -DCMAKE_USE_SYSTEM_LIBLZMA=OFF
            -DCMAKE_USE_SYSTEM_LIBARCHIVE=OFF
            -DCMAKE_USE_SYSTEM_JSONCPP=OFF
            -DCMAKE_USE_SYSTEM_LIBUV=OFF
            -DCMAKE_USE_SYSTEM_FORM=OFF
            -DCMAKE_USE_SYSTEM_CPPDAP=OFF
        )
    fi

    cmake -B "$build_dir" -S "$src_dir" "${cmake_flags[@]}"

    echo "Building $name..."
    ninja -C "$build_dir" -j$(nproc)

    echo "Installing $name..."
    ninja -C "$build_dir" install
}

clone_repo "https://github.com/Kitware/CMake.git" "v$CMAKE_VER" "$ROOT_DIR/cmake-$CMAKE_VER"
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
}' "$ROOT_DIR/cmake-$CMAKE_VER/Source/cmWindowsRegistry.cxx" || true
cp "$ROOT_DIR/patches/cmake/cmCurl.cxx" "$ROOT_DIR/cmake-$CMAKE_VER/Source/cmCurl.cxx"
cd $ROOT_DIR
clone_repo "https://github.com/ninja-build/ninja.git" "v$NINJA_VER" "$ROOT_DIR/ninja-$NINJA_VER"

build_project "CMake" "$ROOT_DIR/cmake-$CMAKE_VER" \
    "$BUILD_DIR/cmake-$CMAKE_VER-$TARGET_TRIPLE" \
    "$BUILD_DIR/binary-cmake-$CMAKE_VER-$TARGET_TRIPLE"

build_project "Ninja" "$ROOT_DIR/ninja-$NINJA_VER" \
    "$BUILD_DIR/ninja-$CMAKE_VER-$TARGET_TRIPLE" \
    "$BUILD_DIR/binary-ninja-$CMAKE_VER-$TARGET_TRIPLE"

echo "Merging Ninja with CMake..."
mkdir -p "$INSTALL_DIR/$CMAKE_VER-$TARGET_TRIPLE"
for thing in "$BUILD_DIR/binary-cmake-$CMAKE_VER-$TARGET_TRIPLE" \
           "$BUILD_DIR/binary-ninja-$CMAKE_VER-$TARGET_TRIPLE"; do
    cp -R "$thing"/. "$INSTALL_DIR/$CMAKE_VER-$TARGET_TRIPLE"
done

echo "Done!"
