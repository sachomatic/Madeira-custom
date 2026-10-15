#!/usr/bin/env bash
# PLAYBOOK 3.2: LLVM 15.0.7 static libraries for iOS arm64, for DXMT's libdxmt_combined.a.
# Output: $ROOT/toolchains/llvm-ios-build/{include,lib/*.a}; sources: $ROOT/toolchains/llvm-project.
# Run in WSL as the normal user. Needs the shims (tools/ios-cross/shims copied to ~/ios-shims).
set -euo pipefail
export PATH=$HOME/ios-shims:$HOME/tools/bin:/usr/lib/llvm-20/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ROOT="${ROOT:-$HOME/madeira-ios}"
SRC="$ROOT/toolchains/llvm-project"
HOST="$ROOT/toolchains/llvm-host-build"
IOS="$ROOT/toolchains/llvm-ios-build"
SDK="${IOS_SDK:-$HOME/ios-sdk/iPhoneOS.sdk}"
JOBS="${JOBS:-$(nproc)}"

# DXMT's iOS slice builds with iOS 17+/18 flags; the libs only need to link there.
MINVER=17.0

# Apple ld has no --gc-sections; AddLLVM must treat iOS like Darwin (-dead_strip).
sed -i 's/MATCHES "Darwin")/MATCHES "Darwin|iOS")/' "$SRC/llvm/cmake/modules/AddLLVM.cmake" || true

if [ ! -x "$HOST/bin/llvm-tblgen" ]; then
    echo "=== stage 1: host llvm-tblgen ==="
    cmake -S "$SRC/llvm" -B "$HOST" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang-20 -DCMAKE_CXX_COMPILER=clang++-20 \
        -DLLVM_TARGETS_TO_BUILD=X86 -DLLVM_ENABLE_PROJECTS= \
        -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_EXAMPLES=Off \
        -DLLVM_ENABLE_ZLIB=Off -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_LIBXML2=Off -DLLVM_ENABLE_TERMINFO=Off
    ninja -C "$HOST" -j"$JOBS" llvm-tblgen
fi

echo "=== stage 2: iOS arm64 libraries ==="
cat > "$ROOT/toolchains/ios-toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_SYSROOT $SDK)
set(CMAKE_OSX_DEPLOYMENT_TARGET $MINVER)
set(CMAKE_C_COMPILER $HOME/ios-shims/ios-clang)
set(CMAKE_CXX_COMPILER $HOME/ios-shims/ios-clang++)
set(CMAKE_AR /usr/lib/llvm-20/bin/llvm-ar)
set(CMAKE_RANLIB /usr/lib/llvm-20/bin/llvm-ranlib)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
EOF
# libc++ in Xcode 26 hides std::unary_function & co. unless asked; LLVM 15 still uses them.
CXXEXTRA="-D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION -D_LIBCPP_ENABLE_CXX17_REMOVED_FEATURES -Wno-deprecated-declarations"
cmake -S "$SRC/llvm" -B "$IOS" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/toolchains/ios-toolchain.cmake" \
    -DCMAKE_CXX_FLAGS="$CXXEXTRA" \
    -DCMAKE_CROSSCOMPILING=ON \
    -DLLVM_TABLEGEN="$HOST/bin/llvm-tblgen" \
    -DLLVM_HOST_TRIPLE=arm64-apple-ios$MINVER -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios$MINVER \
    -DLLVM_TARGET_ARCH=AArch64 -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= \
    -DLLVM_BUILD_TOOLS=Off -DLLVM_BUILD_UTILS=Off -DLLVM_INCLUDE_UTILS=Off \
    -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_EXAMPLES=Off -DLLVM_INCLUDE_DOCS=Off \
    -DLLVM_ENABLE_ZLIB=Off -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_LIBXML2=Off -DLLVM_ENABLE_TERMINFO=Off \
    -DLLVM_ENABLE_BINDINGS=Off -DLLVM_ENABLE_PLUGINS=Off -DLLVM_ENABLE_THREADS=On
# Only the libraries DXMT links (llvm_deps in dxmt/src/airconv/meson.build). `all` would also
# build an iOS llvm-tblgen, which needs -lrt and is useless (the host one is used).
TARGETS=$(grep -o "'-lLLVM[A-Za-z]*'" "$ROOT/dxmt/src/airconv/meson.build" | tr -d "'" | sed 's/^-l//' | sort -u)
echo "targets: $TARGETS" | tr '\n' ' '; echo
ninja -C "$IOS" -j"$JOBS" $TARGETS
echo "Gate 3.2:"; ls "$IOS"/lib/*.a | wc -l; ls "$IOS/include/llvm/Config/llvm-config.h"
f="$(ls "$IOS"/lib/libLLVMSupport.a)"; (cd /tmp && mkdir -p g32 && cd g32 && llvm-ar x "$f" 2>/dev/null; file "$(ls | head -1)")
