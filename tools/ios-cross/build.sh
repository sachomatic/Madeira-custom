#!/usr/bin/env bash
# Build Madeira.ipa on WSL2 Ubuntu / Linux without a Mac. See PLAYBOOK.md and STATE.md.
#
#   build.sh app    Swift/C -> executables -> Madeira.app -> Madeira.ipa -> parity report   (minutes)
#   build.sh libs   the native iOS libraries the app links (PLAYBOOK phase 3)               (~30-60 min)
#   build.sh all    libs, then app
#
# Prerequisites (PLAYBOOK phases 1-2, done once): ~/madeira-ios = checkout + patches, toolchains in
# ~/tools, ~/xtool-sdk and ~/ios-sdk, the official release IPA unpacked in $OFFICIAL, and (for the PE
# folders) your tree's app/Madeira in $OVERLAY. Run with a clean environment: env.sh sets PATH.
#
# STATUS: `build.sh all` was run as one script from `env -i` on 2026-10-14 (20 min, exit 0), on a WSL that already
# had the checkout, toolchains, SDK, caches and the Wine tools tree. GnuTLS is skipped by its own .done markers
# (delete build/gnutls-ios/obj/*.done to force it). Not tested: a brand-new WSL (see STATE.md for the manual setup).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/ios-shims" && cp "$HERE"/shims/* "$HOME/ios-shims/" && chmod +x "$HOME/ios-shims/"*
. "$HERE/env.sh"

OFFICIAL_IPA="${OFFICIAL_IPA:-$HOME/dl/official/Madeira-0.1.3.ipa}"   # same version as MARKETING_VERSION
OFFICIAL="${OFFICIAL:-$HOME/dl/official/x/Payload/Madeira.app}"
OVERLAY="${OVERLAY:-/mnt/c/Users/stard/OneDrive/Documents/code/madeira/Madeira-main/app/Madeira}"
OUT_IPA="${OUT_IPA:-$HOME/Madeira-linux.ipa}"
log() { printf '\n==== %s\n' "$*"; }

unpack_official() {
    [ -d "$OFFICIAL" ] && return 0
    [ -f "$OFFICIAL_IPA" ] || { echo "missing $OFFICIAL_IPA (download the release IPA of this version; see PLAYBOOK 5.1)"; exit 1; }
    mkdir -p "$(dirname "$OFFICIAL")/.." && (cd "$(dirname "$OFFICIAL")/../.." && unzip -q -o "$OFFICIAL_IPA")
}

libs() {
    cd "$REPO"
    unpack_official
    log "Metal-derived headers (from the official IPA)"
    python3 -I "$HERE/extract_metal_headers.py" "$OFFICIAL" build/dxmt-ios/shader-headers
    log "LLVM 15.0.7 for iOS (DXMT)"
    [ -d toolchains/llvm-project ] || git clone --filter=blob:none https://github.com/llvm/llvm-project.git toolchains/llvm-project
    git -C toolchains/llvm-project checkout -q llvmorg-15.0.7
    bash "$HERE/build-llvm-ios.sh"
    log "Wine headers: macOS-style config.h + widl headers (needs ~/madeira/wine/build-arm64ec with native tools)"
    bash "$HERE/configure-wine-macos.sh"
    ( export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      cd "$HOME/madeira/wine/build-arm64ec"
      for idl in ../include/*.idl; do echo "include/$(basename "$idl" .idl).h"; done | xargs make -j"$(nproc)" -k >/dev/null 2>&1 || true )
    mkdir -p wine/build-arm64ec && rsync -a "$HOME/madeira/wine/build-arm64ec/include" wine/build-arm64ec/
    log "small libraries: gnutls, ffmpeg, freetype, rppairing"
    bash build/gnutls-ios/build.sh
    bash build/ffmpeg/build.sh
    [ -d research/freetype ] || git clone --depth 1 --branch VER-2-13-3 https://github.com/freetype/freetype.git research/freetype
    CC="$IOS_SHIMS/ios-clang" CXX="$IOS_SHIMS/ios-clang++" bash build/freetype-ios/build.sh
    bash build/rppairing-ios/build.sh
    log "Wine unix libraries"
    bash "$HERE/wineserver-base.sh"
    bash build/wineserver/build.sh
    bash build/ntdll-unix/build.sh
    bash build/win32u-unix/build.sh
    log "FEX"
    cat > toolchains/ios-ios.cmake <<EOF
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_SYSROOT $IOS_SDK)
set(CMAKE_OSX_DEPLOYMENT_TARGET 17.0)
set(CMAKE_C_COMPILER $IOS_SHIMS/ios-clang)
set(CMAKE_CXX_COMPILER $IOS_SHIMS/ios-clang++)
set(CMAKE_ASM_COMPILER $IOS_SHIMS/ios-clang)
set(CMAKE_AR /usr/lib/llvm-20/bin/llvm-ar)
set(CMAKE_RANLIB /usr/lib/llvm-20/bin/llvm-ranlib)
set(CMAKE_C_COMPILER_AR /usr/lib/llvm-20/bin/llvm-ar)
set(CMAKE_CXX_COMPILER_AR /usr/lib/llvm-20/bin/llvm-ar)
set(CMAKE_C_COMPILER_RANLIB /usr/lib/llvm-20/bin/llvm-ranlib)
set(CMAKE_CXX_COMPILER_RANLIB /usr/lib/llvm-20/bin/llvm-ranlib)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
EOF
    rm -rf FEX/build-ios
    cmake -S FEX -B FEX/build-ios -G Ninja -DCMAKE_TOOLCHAIN_FILE="$REPO/toolchains/ios-ios.cmake" -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF -DBUILD_FEX_LINUX_TESTS=OFF -DENABLE_FEX_ALLOCATOR=OFF \
        -DENABLE_ASSERTIONS=OFF -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=OFF
    cmake --build FEX/build-ios --target FEXCore FEXCore_Base JemallocLibs
    log "DXMT unix side"
    bash build/dxmt-ios/build.sh
    ( cd build/dxmt-ios && xcrun -sdk iphoneos libtool -static -o libdxmt_combined.a obj/*.o ../../toolchains/llvm-ios-build/lib/*.a \
        && cp libdxmt_combined.a ../../app/Madeira/ )
    bash build/stage-licenses.sh
}

app() {
    cd "$REPO"
    unpack_official
    log "os_version_check + Swift/C compile + link"
    python3 -I "$HERE/gen_ninja.py" --repo "$REPO"
    ninja -C build/ios-app
    log "bundle + sign + zip"
    python3 -I "$HERE/bundle.py" --repo "$REPO" --official "$OFFICIAL" --overlay "$OVERLAY" --out "$OUT_IPA"
    log "parity with the official IPA"
    [ -f "$OFFICIAL_IPA" ] && python3 -I "$HERE/parity.py" "$OUT_IPA" "$OFFICIAL_IPA" || echo "(official IPA not present, parity skipped)"
}

case "${1:-app}" in
    libs) libs ;;
    app)  app ;;
    all)  libs; app ;;
    *) echo "usage: $0 [app|libs|all]"; exit 2 ;;
esac
