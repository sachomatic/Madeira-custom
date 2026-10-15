#!/usr/bin/env bash
# Phase 0 of tools/ios-cross/PLAYBOOK.md: report what is present and what is missing.
# Read-only. Run in WSL Ubuntu with a clean PATH. Exit 0 = ready for phase 1.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
REQ="${MADEIRA_REQ:-/mnt/c/Users/stard/OneDrive/Documents/code/sandbox/madeira-requirements}"
ok=0; miss=0
chk() { # label  command...
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then printf '  ok       %s\n' "$label"; else printf '  MISSING  %s\n' "$label"; miss=$((miss+1)); fi
}
echo "== host"
printf '  %s, %s cores, %s GB RAM, %s GB free in $HOME\n' "$(. /etc/os-release; echo $PRETTY_NAME)" "$(nproc)" "$(free -g | awk '/Mem/{print $2}')" "$(df -BG --output=avail ~ | tail -1 | tr -dc 0-9)"
echo "== packages (apt, as root: wsl -d Ubuntu -u root)"
for t in git curl python3 make gcc g++ cmake ninja bison flex autoconf automake libtool pkg-config rsync unzip xz zstd cpio xxd meson ccache clang lld; do chk "$t" command -v $t; done
chk "llvm-ar / llvm-ranlib / llvm-lipo / llvm-libtool-darwin / llvm-install-name-tool (apt: llvm)" bash -c 'for t in llvm-ar llvm-ranlib llvm-lipo llvm-libtool-darwin llvm-install-name-tool llvm-nm llvm-strip llvm-otool; do command -v $t || command -v $t-20 || command -v $t-19 || command -v $t-18 || exit 1; done'
echo "== inputs only the user can supply"
chk "Xcode 26.x .xip in $REQ" bash -c "ls $REQ/Xcode*.xip"
chk "decision recorded in STATE.md (SDK licence)" grep -q '^- \[x\] DECISION' "$(dirname "$0")/STATE.md"
echo "== toolchains (phase 2 installs these)"
chk "swift 6.x" command -v swiftc
chk "xtool" command -v xtool
chk "ldid" command -v ldid
chk "rustup + aarch64-apple-ios" bash -c 'rustup target list --installed | grep -q aarch64-apple-ios'
chk "iPhoneOS SDK ($HOME/ios-sdk/iPhoneOS.sdk)" test -d "$HOME/ios-sdk/iPhoneOS.sdk"
echo
[ "$miss" = 0 ] && echo "READY" || echo "$miss item(s) missing; see PLAYBOOK.md for which phase provides each"
exit $((miss > 0))
