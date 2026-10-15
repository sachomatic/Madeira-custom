#!/usr/bin/env bash
# PLAYBOOK 3.5: create the base libwineserver.a that build/wineserver/build.sh expects to patch
# (the original is a prebuilt, untracked archive). Compiles every wine/server/*.c listed in
# Makefile.in SOURCES with the CC_FLAGS taken verbatim from build/wineserver/build.sh, then
# archives them as obj/<name>.o, which is how build.sh names the members it replaces.
# Files that fail are reported and left out (build.sh recompiles the patched ones itself).
set -uo pipefail
export PATH=$HOME/ios-shims:$HOME/tools/bin:/usr/lib/llvm-20/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ROOT="${ROOT:-$HOME/madeira-ios}"
BUILD_DIR="$ROOT/build/wineserver"
WINE_SRC="$ROOT/wine"
OBJ_DIR="$BUILD_DIR/obj"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SHIMS_DIR="$ROOT/build/ntdll-unix/shims"
mkdir -p "$OBJ_DIR/base"

# Pull the CC_FLAGS=( ... ) array out of build.sh and evaluate it here, so both stay in sync.
eval "$(awk '/^CC_FLAGS=\(/,/^\)/' "$BUILD_DIR/build.sh")"

SRCS=$(sed -n '/^SOURCES/,/^$/p' "$WINE_SRC/server/Makefile.in" | tr -d '\\' | tr -s ' \t\n' '\n' | grep '\.c$')
ok=0; bad=""
for f in $SRCS; do
    n="${f%.c}"
    if xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$WINE_SRC/server/$f" -o "$OBJ_DIR/base/$n.o" 2>"$OBJ_DIR/base/err-$n.txt"; then
        ok=$((ok+1))
    else
        bad="$bad $n"; rm -f "$OBJ_DIR/base/$n.o"
    fi
done
echo "base objects: $ok ok, failed:${bad:- none}"
rm -f "$OBJ_DIR/libwineserver.a"
ar rcs "$OBJ_DIR/libwineserver.a" "$OBJ_DIR"/base/*.o
echo "-> $OBJ_DIR/libwineserver.a ($(wc -c < "$OBJ_DIR/libwineserver.a") bytes)"
nm -g "$OBJ_DIR/libwineserver.a" 2>/dev/null | grep -c ' T _wineserver_main' || true
