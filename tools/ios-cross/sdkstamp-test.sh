#!/bin/bash
# Experiment: which swiftc flag stamps the iOS SDK version (LC_BUILD_VERSION "sdk") into a linked binary.
# Run: wsl.exe -d Ubuntu -e bash /mnt/c/Users/stard/OneDrive/Documents/code/madeira/Madeira-main/tools/ios-cross/sdkstamp-test.sh
set -u
. "$(dirname "$0")/env.sh"
W="$HOME/scratch-lg/t"; rm -rf "$W"; mkdir -p "$W"; cd "$W"
echo 'let x = 1' > main.swift
show() { /usr/lib/llvm-20/bin/llvm-objdump --macho --private-headers "$1" | grep -A4 LC_BUILD_VERSION | tr -s ' ' | tr '\n' ' '; echo; }
S="swiftc -target arm64-apple-ios17.0 -sdk $IOS_SDK -resource-dir $SWIFT_RES/lib/swift -use-ld=/usr/lib/llvm-20/bin/ld64.lld -Xclang-linker -mlinker-version=1000 main.swift"
try() { name=$1; shift; "$@" -o "$name" >"$name.out" 2>&1 && { printf '%-24s ' "$name"; show "$name"; } || { echo "$name FAILED: $(tail -c 400 $name.out)"; }; }
try a-current        $S
try b-target-sdk-ver $S -target-sdk-version 26.5
try c-xlinker        $S -Xlinker -platform_version -Xlinker ios -Xlinker 17.0 -Xlinker 26.5
echo "--- link line of (a):"; $S -o /dev/null -v 2>&1 | grep -o -E -- "-platform_version[^\"]*|ios_version_min[^\"]*" | head -3
