# Sourced by the shims. Override any of these from the environment.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SHIMS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${LLVM_BIN:=/usr/lib/llvm-20/bin}"
: "${IOS_SDK:=$HOME/ios-sdk/iPhoneOS.sdk}"
: "${IOS_MIN:=17.0}"
# Marker "SDK" for `xcrun --sdk macosx`: clang shims that see it as -isysroot
# build for the Linux host instead (autotools CC_FOR_BUILD).
HOST_SYSROOT="$SHIMS_DIR/host-sysroot"
llvm_tool() { # name -> path of llvm-<name>, trying the versioned dir first
    for c in "$LLVM_BIN/$1" "$LLVM_BIN/llvm-$1" "$(command -v "llvm-$1-20" 2>/dev/null)" "$(command -v "llvm-$1" 2>/dev/null)"; do
        [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
    done
    echo "shim: missing llvm tool $1" >&2; return 1
}
