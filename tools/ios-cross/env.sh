# Source me (WSL Ubuntu): toolchain environment for the Linux iOS build. See PLAYBOOK.md.
# Expected layout (created by phase 2): ~/tools/{bin,swift}, ~/xtool-sdk, ~/ios-sdk/iPhoneOS.sdk,
# ~/swift-res (merged resource dir), ~/ios-shims (copy of tools/ios-cross/shims, chmod +x).
export IOS_SHIMS="${IOS_SHIMS:-$HOME/ios-shims}"
export IOS_SDK="${IOS_SDK:-$HOME/ios-sdk/iPhoneOS.sdk}"
export XTOOL_SDK="${XTOOL_SDK:-$HOME/xtool-sdk/darwin.xtoolsdk}"
export XTOOL_TOOLSET="$XTOOL_SDK/toolset/bin"
export SWIFT_RES="${SWIFT_RES:-$HOME/swift-res}"
export REPO="${REPO:-$HOME/madeira-ios}"
# clean PATH on purpose: WSL appends the Windows PATH, and a Windows Miniconda broke a build once
export PATH="$IOS_SHIMS:$HOME/tools/bin:$HOME/tools/swift/usr/bin:$HOME/.cargo/bin:/usr/lib/llvm-20/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# widl-generated headers that only the arm64ec tree has (winegstreamer/dwrite unix libs)
export CPATH="$REPO/wine/build-arm64ec/include${CPATH:+:$CPATH}"

# One-time: merged Swift resource dir. Swift looks for clang's builtin headers (stddef.h,
# stdarg.h, ...) in <resource-dir>/clang. In xtool's Xcode toolchain that is a symlink to a clang
# dir WITHOUT include/, so the SDK's obsolete stddef.h wins and module import fails
# ("found_incompatible_headers__check_search_paths"). So: lib/swift is a real directory with
# Xcode's entries (Darwin .swiftmodules, iphoneos libs) symlinked, and `clang` pointing at the
# Linux Swift toolchain's clang resource dir. lib/clang/<ver> is kept for -Xcc -resource-dir.
ios_cross_setup_swift_res() {
    [ -f "$SWIFT_RES/lib/swift/.merged" ] && return 0
    local xs="$XTOOL_SDK/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
    local clang_dir; clang_dir="$(ls -d "$HOME"/tools/swift/usr/lib/clang/* | head -1)"
    rm -rf "$SWIFT_RES"; mkdir -p "$SWIFT_RES/lib/swift" "$SWIFT_RES/lib/clang"
    local e
    for e in "$xs"/* "$xs"/.[!.]*; do
        [ -e "$e" ] || continue
        [ "$(basename "$e")" = clang ] && continue
        ln -s "$e" "$SWIFT_RES/lib/swift/$(basename "$e")"
    done
    ln -s "$clang_dir" "$SWIFT_RES/lib/swift/clang"
    ln -s "$clang_dir" "$SWIFT_RES/lib/clang/$(basename "$clang_dir")"
    touch "$SWIFT_RES/lib/swift/.merged"
}
ios_cross_setup_swift_res
