#!/usr/bin/env bash
# Rebuild the Windows-side pieces of a Madeira release and put them into that
# release's IPA, without a Mac. Works for any release: it reads the version
# from the IPA, asks GitHub which wine and madeira-dock commits that release
# pins, builds those commits (plus the patches in patches/), and swaps the
# results in. Linux or WSL2 Ubuntu; also what .github/workflows/fix-ipa.yml runs.
#
#   madeira-fix.sh --version 0.1.3                 download the official IPA, fix it
#   madeira-fix.sh --ipa Madeira-0.1.3.ipa         fix an IPA you already have
#
# Options
#   --out FILE          output IPA (default: <ipa name>-fixed.ipa next to the input / in $PWD)
#   --modules "a b"     Wine modules to build into arm64ec-windows (default: tbs)
#   --no-dock           leave Madeira Dock's host alone
#   --check             also run Dock's unit tests (needs gcc with ASan/UBSan)
#   --vcruntime DIR     put the files of DIR into x86_64-vcruntime/ (Microsoft's
#                       Visual C++ runtime DLLs; you supply them, see docs/BUILDING.md)
#   --wine-ref SHA / --dock-ref SHA   build these commits instead of the release's pins
#   --repo owner/name   upstream repository (default willfaust/Madeira)
#   --work DIR          cache directory (default ~/.cache/madeira-fix)
#
# What it can change: only files that are Windows binaries inside the IPA
# (Dock's host, Wine modules). Changes to the app itself (Swift) or to the iOS
# libraries need a Mac build. The IPA's signature is broken by the change; your
# sideloader signs it again.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="willfaust/Madeira"
WORK="${MADEIRA_FIX_WORK:-$HOME/.cache/madeira-fix}"
IPA="" VERSION="" OUT="" MODULES="tbs" DO_DOCK=1 CHECK=0 VCRT="" WINE_REF="" DOCK_REF=""
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# llvm-mingw, pinned: Madeira's own pin (docs/BUILDING.md); the Linux builds.
TC_VER=20260421
case "$(uname -m)" in
    x86_64)  TC_NAME=llvm-mingw-$TC_VER-ucrt-ubuntu-22.04-x86_64;  TC_SHA=f8b8cce779affeab47bcaec6ce6e9e768b166094a366123ef64b2d0b389cc121 ;;
    aarch64) TC_NAME=llvm-mingw-$TC_VER-ucrt-ubuntu-22.04-aarch64; TC_SHA=e9cfa5a93290cb852dc5a6b90ccde255403a63332648be171470ca3c1ad37828 ;;
    *) echo "unsupported host $(uname -m)" >&2; exit 1 ;;
esac

die() { echo "madeira-fix: $*" >&2; exit 1; }
log() { printf '\n== %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --ipa) IPA="$2"; shift 2 ;;
        --version) VERSION="${2#v}"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --modules) MODULES="$2"; shift 2 ;;
        --no-dock) DO_DOCK=0; shift ;;
        --check) CHECK=1; shift ;;
        --vcruntime) VCRT="$2"; shift 2 ;;
        --wine-ref) WINE_REF="$2"; shift 2 ;;
        --dock-ref) DOCK_REF="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --work) WORK="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1 (--help)" ;;
    esac
done
[ -n "$IPA$VERSION" ] || die "give --ipa FILE or --version X.Y.Z (--help)"

missing=()
for t in git curl python3 make gcc bison flex xz tar sha256sum; do command -v "$t" >/dev/null || missing+=("$t"); done
[ ${#missing[@]} -eq 0 ] || die "missing tools: ${missing[*]}  (Ubuntu: sudo apt install git curl python3 make gcc bison flex xz-utils)"
mkdir -p "$WORK"

api() { # path -> JSON on stdout
    local auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
}

# ---------------------------------------------------------------- the IPA
if [ -z "$IPA" ]; then
    IPA="$WORK/Madeira-$VERSION.ipa"
    if [ ! -f "$IPA" ]; then
        log "downloading Madeira-$VERSION.ipa from github.com/$REPO releases"
        base="https://github.com/$REPO/releases/download/v$VERSION"
        curl -fL --retry 3 -o "$IPA.part" "$base/Madeira-$VERSION.ipa"
        if curl -fsSL "$base/Madeira-$VERSION.ipa.sha256" -o "$IPA.sha256"; then
            want="$(awk '{print $1}' "$IPA.sha256" | head -1)"
            got="$(sha256sum "$IPA.part" | awk '{print $1}')"
            [ "$want" = "$got" ] || { rm -f "$IPA.part"; die "checksum mismatch for the downloaded IPA"; }
            echo "sha256 ok ($got)"
        else
            echo "no .sha256 published for this release; not verified"
        fi
        mv "$IPA.part" "$IPA"
    fi
fi
[ -f "$IPA" ] || die "$IPA not found"
IPA_VERSION="$(python3 "$HERE/patch_ipa.py" version "$IPA")"
[ -n "$IPA_VERSION" ] || die "cannot read the version from $IPA"
[ -z "$VERSION" ] || [ "$VERSION" = "$IPA_VERSION" ] || echo "note: IPA says $IPA_VERSION, you asked for $VERSION; using the IPA's"
VERSION="$IPA_VERSION"
echo "IPA: $IPA  (Madeira $VERSION)"
[ -n "$OUT" ] || OUT="$(pwd)/$(basename "${IPA%.ipa}")-fixed.ipa"

# ------------------------------------------------------ pinned commits
if [ -z "$WINE_REF" ] || { [ "$DO_DOCK" = 1 ] && [ -z "$DOCK_REF" ]; }; then
    log "which wine / madeira-dock commits does v$VERSION pin"
    pins="$(api "repos/$REPO/git/trees/v$VERSION" | python3 -c '
import json, sys
for e in json.load(sys.stdin).get("tree", []):
    if e["type"] == "commit": print(e["path"], e["sha"])')"
    [ -n "$pins" ] || die "no tag v$VERSION in $REPO (or the API refused: set GITHUB_TOKEN); use --wine-ref/--dock-ref"
    [ -n "$WINE_REF" ] || WINE_REF="$(awk '$1=="wine"{print $2}' <<<"$pins")"
    [ -n "$DOCK_REF" ] || DOCK_REF="$(awk '$1=="madeira-dock"{print $2}' <<<"$pins")"
fi
echo "wine $WINE_REF"; [ "$DO_DOCK" = 0 ] || echo "madeira-dock $DOCK_REF"

fetch() { # name url sha [dir] -> checked-out dir (default: in $WORK)
    local dir="${4:-$WORK/src-$1-${3:0:12}}"
    if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" != "$3" ]; then
        rm -rf "$dir"; mkdir -p "$dir"
        git -C "$dir" init -q
        git -C "$dir" fetch -q --depth 1 "$2" "$3" || die "cannot fetch $3 from $2"
        git -C "$dir" checkout -q FETCH_HEAD
    fi
    # Always start from the pinned commit: a cached tree may still hold patches from an earlier run.
    git -C "$dir" reset -q --hard "$3"
    git -C "$dir" clean -qfdx
    echo "$dir"
}

apply_queue() { # srcdir patchdir
    local p
    [ -d "$2" ] || return 0
    for p in "$2"/*.patch; do
        [ -e "$p" ] || continue
        if git -C "$1" apply --check "$p" 2>/dev/null; then
            git -C "$1" apply "$p"; echo "patch applied:        $(basename "$p")"
        elif git -C "$1" apply -R --check "$p" 2>/dev/null; then
            echo "patch already in tree: $(basename "$p")"
        else
            die "patch does not apply to this version: $(basename "$p") (the version changed that code; update the patch)"
        fi
    done
}

# ------------------------------------------------------------ toolchain
TC="$WORK/$TC_NAME"
if [ ! -x "$TC/bin/arm64ec-w64-mingw32-clang" ]; then
    log "llvm-mingw $TC_VER"
    f="$WORK/$TC_NAME.tar.xz"
    [ -f "$f" ] || curl -fL --retry 3 -o "$f" "https://github.com/mstorsjo/llvm-mingw/releases/download/$TC_VER/$TC_NAME.tar.xz"
    echo "$TC_SHA  $f" | sha256sum -c - || { rm -f "$f"; die "toolchain checksum mismatch"; }
    tar -xf "$f" -C "$WORK"
fi
STAGE="$WORK/out-$VERSION"; rm -rf "$STAGE"; mkdir -p "$STAGE"
put=()

# ---------------------------------------------------------------- Dock
if [ "$DO_DOCK" = 1 ]; then
    log "Madeira Dock host"
    D="$(fetch madeira-dock https://github.com/willfaust/madeira-dock.git "$DOCK_REF")"
    apply_queue "$D" "$HERE/patches/madeira-dock"
    [ "$CHECK" = 0 ] || (cd "$D" && HOST_CC="${HOST_CC:-gcc}" bash tools/check.sh)
    # Same flags as Dock's tools/build.sh and Madeira's build/madeira-dock/build.sh.
    "$TC/bin/x86_64-w64-mingw32-clang" -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type \
        -static -Wl,--strip-all -Wl,--no-insert-timestamp \
        -o "$STAGE/dockhost.exe" "$D"/src/*.c -ladvapi32
    {
        cat "$D/LICENSE"
        printf '\nCorresponding source: https://github.com/125hz/madeira-dock (commit %s)\n' "$DOCK_REF"
        printf '\n\n==== %s ====\n\n' 'LICENSE-EXCEPTION.md (Madeira Converter Exception)'; cat "$D/LICENSE-EXCEPTION.md"
        printf '\n\n==== %s ====\n\n' 'COPYING (GNU General Public License, version 3)'; cat "$D/COPYING"
        printf '\n\n==== %s ====\n\n' 'MinGW-w64 runtime notice (statically linked runtime)'; cat "$D/notices/MinGW-w64-runtime.txt"
        printf '\n\n==== %s ====\n\n' 'LLVM runtime notice'; cat "$D/notices/LLVM.txt"
    } > "$STAGE/dock-notices.txt"
    put+=(--put "arm64ec-windows=$STAGE/dockhost.exe" --put "arm64ec-windows=$STAGE/dock-notices.txt")
fi

# --------------------------------------------------------- Wine modules
if [ -n "$MODULES" ]; then
    log "Wine modules: $MODULES"
    # The Wine fork includes ../../../../build/madeira_cfg.h from the Madeira repository
    # (dlls/ntdll/unix), so wine/ must sit next to a build/ folder that has it.
    TREE="$WORK/tree-${WINE_REF:0:12}"
    mkdir -p "$TREE/build"
    W="$(fetch wine https://github.com/willfaust/wine.git "$WINE_REF" "$TREE/wine")"
    if [ ! -s "$TREE/build/madeira_cfg.h" ]; then
        curl -fsSL "https://raw.githubusercontent.com/$REPO/v$VERSION/build/madeira_cfg.h" -o "$TREE/build/madeira_cfg.h"             || curl -fsSL "https://raw.githubusercontent.com/$REPO/main/build/madeira_cfg.h" -o "$TREE/build/madeira_cfg.h"             || die "cannot fetch build/madeira_cfg.h from $REPO"
    fi
    apply_queue "$W" "$HERE/patches/wine"
    B="$WORK/build-wine-${WINE_REF:0:12}"
    export PATH="$TC/bin:$PATH"
    if [ ! -f "$B/config.status" ]; then
        mkdir -p "$B"
        # --without-freetype: only PE modules are built, so no host libraries are needed.
        (cd "$B" && "$W/configure" --enable-archs=arm64ec --without-x --without-freetype \
            --disable-tests --enable-winegstreamer >"$B/configure.log" 2>&1) \
            || { tail -20 "$B/configure.log"; die "wine configure failed (log: $B/configure.log)"; }
    fi
    # widl looks for stdole2.tlb under aarch64-windows/ for an ARM64EC typelib import.
    mkdir -p "$B/dlls/stdole2.tlb"
    [ -e "$B/dlls/stdole2.tlb/aarch64-windows" ] || ln -s arm64ec-windows "$B/dlls/stdole2.tlb/aarch64-windows"
    targets=()
    for m in $MODULES; do
        [ -f "$W/dlls/$m/Makefile.in" ] || die "no wine module '$m' in this Wine version"
        case "$m" in *.*) f="$m" ;; *) f="$m.dll" ;; esac
        targets+=("dlls/$m/arm64ec-windows/$f")
    done
    make -C "$B" -j"$JOBS" "${targets[@]}" >"$B/make.log" 2>&1 || { tail -30 "$B/make.log"; die "wine build failed (log: $B/make.log)"; }
    for t in "${targets[@]}"; do
        cp "$B/$t" "$STAGE/$(basename "$t")"
        "$TC/bin/arm64ec-w64-mingw32-strip" --strip-debug "$STAGE/$(basename "$t")"
        put+=(--put "arm64ec-windows=$STAGE/$(basename "$t")")
    done
fi

[ -z "$VCRT" ] || put+=(--put-dir "x86_64-vcruntime=$VCRT")

# ------------------------------------------------------------------ IPA
log "patching the IPA"
python3 "$HERE/patch_ipa.py" patch "$IPA" -o "$OUT" "${put[@]}"
echo
echo "Done: $OUT"
echo "Sideload it over the installed Madeira (games, saves and the prefix are kept)."
