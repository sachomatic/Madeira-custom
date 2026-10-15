#!/bin/bash
# Print the LC_BUILD_VERSION (platform / sdk / minos) of the app's Mach-O files after `build.sh app`.
# iOS 26+ draws Liquid Glass only for binaries whose sdk is 26 or newer.
# Run: wsl.exe -d Ubuntu -e bash /mnt/c/Users/stard/OneDrive/Documents/code/madeira/Madeira-main/tools/ios-cross/check-sdkstamp.sh
cd "${1:-$HOME/madeira-ios/build/ios-app/Payload/Madeira.app}" || exit 1
for f in Madeira PlugIns/MadeiraJITHelper.appex/MadeiraJITHelper Frameworks/StikJIT.framework/StikJIT; do
    printf '%-52s' "$f"
    /usr/lib/llvm-20/bin/llvm-objdump --macho --private-headers "$f" | grep -A4 LC_BUILD_VERSION | tr -s ' ' | tr '\n' ' '
    echo
done
