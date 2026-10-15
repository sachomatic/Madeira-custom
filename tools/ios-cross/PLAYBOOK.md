# Playbook: build the Madeira iOS app from Windows (WSL2) / Linux, no Mac

Written for a fresh session of Claude with no memory of the earlier work. Read
this file, then `STATE.md` (what is done), then continue at the first
unchecked gate. Update `STATE.md` after every gate. Do not skip a gate: each
one is a cheap test that stops a wrong assumption from costing hours later.

Goal: `build.sh` that turns a checkout of `willfaust/Madeira` (any ref, plus
the user's patches) into an unsigned-but-entitled `Madeira.ipa`, on WSL2
Ubuntu 24.04, so the user can edit anything and rebuild. Parity target: the
official release IPA of the same version (same file list, same Info.plist,
same entitlements). Honest status when written: **nothing in phases 2-5 has
been run**; every step below is a plan with a test, not a result.

## 0. Facts already established (do not re-derive)

- User: Windows 11, 24 cores, 15 GB RAM visible to WSL, ~250 GB free, WSL
  distro `Ubuntu` (24.04), root available through `wsl -d Ubuntu -u root`
  (no sudo password). No Mac, little money: everything must be free.
- Run WSL commands from PowerShell/Bash with scripts in files; inline quoting
  breaks. WSL appends the Windows PATH: always `export
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` (a Windows
  Miniconda's `fmt` headers once broke a build). Git Bash mangles `/mnt/...`
  arguments: use `MSYS_NO_PATHCONV=1` or PowerShell.
- Build on WSL's disk (`~/madeira-ios`), never on `/mnt/c` (OneDrive syncs it).
  Downloads the user must keep go in
  `C:\Users\stard\OneDrive\Documents\code\sandbox\madeira-requirements\`
  (= `/mnt/c/Users/stard/OneDrive/Documents/code/sandbox/madeira-requirements`).
  The folder `sandbox/` also holds unrelated NumWorks files: do not touch them.
- Source of truth: `C:\Users\stard\OneDrive\Documents\code\madeira\Madeira-main`
  (upstream `willfaust/Madeira` `main` @ `48f97642` + the user's changes, all
  of which are in `tools/ios-cross/patches/madeira/`). Submodules: wine
  (branch `madeira-lgpl`), FEX (`ios-port-2607`), dxmt (`ios-port`),
  madeira-dock (`main`), all under github.com/willfaust. For a release, use
  the commits the release tag pins (`tools/madeira-fix/madeira-fix.sh` shows
  how: GitHub API `git/trees/<tag>`).
- The Windows side already builds on Linux and is done: `docs/BUILDING.md`
  section "Building the Windows side without a Mac", `tools/madeira-fix/`,
  `build/setup-linux-host.sh`, outputs in `build/out-linux/`. The PE binaries
  in `app/Madeira/*-windows/` are tracked in git, so the app build does not
  need to rebuild them. llvm-mingw for Linux is in `~/madeira/toolchains/`.
- What cannot be done without Apple software, and the planned replacement:

  | Apple-only piece | Replacement |
  |---|---|
  | iOS SDK (headers, `.tbd` stubs, `.swiftinterface`) | extracted from Xcode 26.x `.xip` (user downloads), by `xtool sdk` |
  | `xcrun`, `libtool`, `lipo`, `codesign` | shims in `tools/ios-cross/shims/` over LLVM tools and `ldid` |
  | Apple clang / ld64 | clang + `ld64.lld` from LLVM 20 (apt.llvm.org) or the Swift toolchain |
  | `swiftc` | swift.org Linux toolchain 6.4.x (newer than Xcode 26's, so it can read the SDK's interfaces) |
  | `xcodebuild` | our own ninja generator reading `app/Madeira.xcodeproj/project.pbxproj` |
  | `metal` / `metallib` (Metal compiler, macOS binary) | reuse the official IPA's `default.metallib`; carve DXMT's embedded metallib out of the official executable; only if shaders are edited, compile on a free GitHub macOS runner |
  | `actool` (asset catalogs -> `Assets.car`) | reuse `Assets.car` from the official IPA; same fallback |
  | `codesign` with entitlements | `ldid -S<entitlements>` (ad-hoc); the user's sideloader re-signs |
- Project facts (from `project.pbxproj`, 2026-10-13): app target deployment
  iOS 17.0 (JIT helper appex 26.0), `SWIFT_VERSION = 5.0`, bridging header
  `Madeira/Madeira-Bridging-Header.h`, `CLANG_ENABLE_MODULES = YES`, 38 Swift
  files in `app/Madeira` + `SwiftSteam/` + `Winios/` + `MadeiraJITHelper/`,
  11 C/ObjC/ObjC++/Metal files, bundle id `com.willfaust.madeora`. Frameworks:
  AudioToolbox, CoreFoundation, CoreMedia, CoreVideo, ExtensionFoundation,
  IOKit, Metal, MetalFX, QuartzCore, VideoToolbox, StikJIT.xcframework
  (prebuilt, tracked). Swift imports include SwiftUI (Liquid Glass in
  `GlassSkin.swift`: needs the **iOS 26 SDK**), UIKit, CryptoKit, Network,
  Compression, BackgroundTasks, GameController, dnssd. The released IPA is the
  **Debug** configuration (Release has crashed the guest) and contains
  `Madeira.debug.dylib` and `__preview.dylib` (Xcode artifacts; a single
  executable is expected to be fine, verify at gate 5.6).
- Prebuilt/tracked iOS libs: `app/Madeira/lib{gmp,nettle,hogweed,gnutls}.a`,
  `app/libdxmt_unix.a`. Built by the dev's scripts and **not in git**:
  `libntdll_unix.a`, `libwineserver.a`, `libwin32u_unix.a`,
  `libdxmt_combined.a`, `libmadeira_rppairing.a`, `libav{format,codec,util}.a`,
  `libswresample.a`, `FEX/build-ios/**`.

## 1. What the user must supply (ask for exactly these, nothing else)

1. **Decision on Apple's licence.** Xcode's licence limits use of its SDKs to
   Apple-branded hardware. Using the iOS SDK on Windows/Linux is therefore
   against Apple's terms; it is the user's call. Write the answer in `STATE.md`
   (`- [x] DECISION: user accepts ...`) before touching the SDK. Without it,
   stop at phase 2 and use only the macOS-runner hybrid (section 7).
2. **Xcode 26.x `.xip`** (about 3 GB). The user downloads it in their own
   browser while signed in with a free Apple ID at
   <https://developer.apple.com/download/all/> ("Xcode 26.x", not a beta unless
   the app needs it) and saves it into `madeira-requirements\`. Claude cannot
   sign in and must not ask for the password. Claude may open the page in the
   built-in browser for them.
3. **Ask the maintainer for the two undocumented build inputs** (largest
   shortcut in the whole plan). Send via the Discord invite in `README.md`
   (<https://discord.gg/4t5mNjwCn7>) or a GitHub issue on willfaust/Madeira:

   > Hi! I'm trying to build Madeira from a clean checkout without a Mac. Two
   > things the repo doesn't say: (1) the exact `configure` command used for
   > `wine/build-macos` (build/ntdll-unix, win32u-unix and wineserver read its
   > `include/config.h`), and (2) how the base `libwineserver.a` that
   > `build/wineserver/build.sh` patches is produced (which server/*.c objects
   > and flags). Also, which LLVM is `toolchains/llvm-ios-build` (15.0.7 per
   > dxmt-ios/README, or commit 8dfdcc7b7 per BUILDING.md) and its cmake flags?
   > Thanks!

   Paste any answer into `STATE.md` under "Answers". Do not wait for it:
   section 4 has the fallback.
4. **Permission to download**, listed in phase 2 with sizes. Ask once for the
   whole list; the user has already allowed GitHub clones, llvm-mingw, and
   `wsl -u root apt install`.
5. Optional: a **public GitHub repo** (free macOS runner) for section 7.

Computer control is not needed. A browser is needed only for items 2 and 3.

## 2. Phase 1: workspace and patches

```
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
git clone --recurse-submodules https://github.com/willfaust/Madeira.git ~/madeira-ios   # ~1.5 GB
cd ~/madeira-ios && git checkout <REF>            # default: 48f97642 (main); a release: its tag
git submodule update --init --recursive
for p in /mnt/c/.../Madeira-main/tools/ios-cross/patches/madeira/*.patch; do patch -p1 -N < $p; done
```
Plus `tools/madeira-fix/patches/madeira-dock/*` into madeira-dock (skip if
already applied) and `dist/frostpunk-dxmt/dxmt-gs-instance-id.patch` into dxmt.
Gate 1.1: `git status` shows only the intended files; `bash
tools/ios-cross/phase0-check.sh` runs.

## 3. Phase 2: toolchains (downloads; ask first)

| Item | Source | Size | Gate |
|---|---|---|---|
| LLVM 20 clang/lld/llvm-tools | apt.llvm.org script as root (`wsl -u root`) | ~600 MB | `clang-20 --version`, `ld64.lld-20 --version` |
| Swift 6.4.x Linux toolchain | swift.org/install (tarball `swift-6.4.1-RELEASE-ubuntu24.04.tar.gz`, or via swiftly) | ~1 GB | `swiftc --version` prints 6.4.x |
| xtool 1.21+ (MIT) | github.com/xtool-org/xtool releases, `xtool-x86_64.AppImage` | ~100 MB | `xtool --version` (AppImage needs `--appimage-extract-and-run` under WSL if FUSE is missing) |
| ldid | github.com/ProcursusTeam/ldid releases `ldid_linux_x86_64` | small | `ldid` prints usage |
| Rust + `aarch64-apple-ios` | rustup.rs, `rustup target add aarch64-apple-ios` | ~1 GB | `rustc --print target-list | grep aarch64-apple-ios$` |
| cctools/ld64 (only if ld64.lld cannot link the app) | github.com/tpoechtrager/cctools-port | build from source | fallback only |

SDK: `xtool sdk` (see `xtool sdk --help`; it consumes the `.xip`) or manually
`7z x Xcode*.xip` -> `pbzx`/`cpio` extract
`Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.*.sdk`
into `~/ios-sdk/iPhoneOS.sdk` (delete everything else; keep ~5 GB).
Gate 2.1: `ls ~/ios-sdk/iPhoneOS.sdk/System/Library/Frameworks/SwiftUI.framework`
and `grep -r glassEffect ~/ios-sdk/iPhoneOS.sdk/System/Library/Frameworks/SwiftUI.framework | head -1` finds the iOS 26 API.
Gate 2.2 (the first real unknown): compile a 10-line SwiftUI+UIKit file for
`arm64-apple-ios17.0` against the SDK with `swiftc`, link it with `ld64.lld`
into a Mach-O, `ldid -S` it, and confirm `file` says Mach-O arm64. If this
fails, fix it here (flags: `-sdk`, `-target`, `-use-ld=lld`, `-Xlinker
-syslibroot`) before anything else; this decides whether the whole plan works.

## 4. Phase 3: shims and the native iOS libraries

3.1 **Shims** (`tools/ios-cross/shims/`, put first on PATH). The repo's
scripts call `xcrun -sdk iphoneos clang ...`, `xcrun --sdk iphoneos
--show-sdk-path`, `xcrun -f ar|ranlib|nm|strip|clang++`, `xcrun --sdk macosx
--show-sdk-path`, `libtool -static`, `lipo`, `sysctl -n hw.ncpu`, `xcrun -sdk
macosx metal/metallib`. Write: `xcrun` (parse `-sdk`, `--sdk`, `-f`,
`--show-sdk-path`; for iphoneos map `clang`/`clang++` to `clang-20
-target arm64-apple-ios$MIN -isysroot $SDK -fuse-ld=lld` where `$MIN` is taken
from an explicit `-miphoneos-version-min=` if present; `ar/ranlib/nm/strip` to
the `llvm-*` tools; `metal`/`metallib` to a stub that fails with a message;
`--sdk macosx` returns the Linux host so autotools `CC_FOR_BUILD` uses gcc),
`libtool`, `lipo`, `codesign`, `sysctl`, `install_name_tool`, `otool`.
Gate 3.1: `xcrun -sdk iphoneos clang -arch arm64 -isysroot "$(xcrun --sdk
iphoneos --show-sdk-path)" -miphoneos-version-min=17.0 -c t.c -o t.o && file
t.o` says Mach-O arm64. `-arch arm64` must be accepted (it is only legal for a
Darwin `-target`; the shim adds the target).

3.2 **LLVM for iOS** (DXMT's `libdxmt_combined.a` links its `.a` files).
Determine the version first: `grep -rn "LLVM_VERSION" dxmt/src/airconv | head`
and `dxmt/build/dxmt-ios/README`; BUILDING.md says commit `8dfdcc7b7`
(libc++ fix, mid-2022), the dxmt README says 15.0.7. Check
`git merge-base --is-ancestor 8dfdcc7b7 llvmorg-15.0.7` in a blobless clone
(`git clone --filter=blob:none https://github.com/llvm/llvm-project`). Use
15.0.7 unless the maintainer answered otherwise. Build: native `llvm-tblgen`
into `toolchains/llvm-host-build`, then the iOS build into
`toolchains/llvm-ios-build` with a CMake toolchain file: `CMAKE_SYSTEM_NAME
Darwin`, `CMAKE_C_COMPILER` = the shim-wrapped clang with `-target
arm64-apple-ios17.0 -isysroot`, `-DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS=
-DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_TESTS=Off -DLLVM_ENABLE_ZLIB=Off
-DLLVM_TABLEGEN=<host> -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0
-DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 -DLLVM_TARGET_ARCH=host
-DCMAKE_BUILD_TYPE=Release`; the AddLLVM.cmake edit `MATCHES "Darwin"` ->
`"Darwin|iOS"` is for `CMAKE_SYSTEM_NAME=iOS` only (with `Darwin` it is
unnecessary; if the linker complains about `--gc-sections`, apply it). Tools
are off, so only static libs build; about 1-2 h on 24 cores. Gate 3.2:
`toolchains/llvm-ios-build/lib/*.a` exist, `llvm-config.h` exists, and `file`
on one `.o` inside says arm64 Mach-O.

3.3 **Wine configure tree `wine/build-macos`.** If the maintainer answered, use
it. Fallback: `mkdir wine/build-macos && cd wine/build-macos && ../configure
--host=aarch64-apple-darwin --enable-win64 --without-x --disable-tests
--without-freetype --without-gnutls --without-vulkan CC=<shim clang> ...`, then
`make -j include tools/winebuild tools/widl tools/wrc` (only `include/config.h`
and generated headers are consumed; also `dlls/ntdll` generated files if
`build/ntdll-unix/build.sh` complains). Configure for a Darwin host cannot run
test programs: pass cache variables (`ac_cv_*`) as needed. Gate 3.3:
`build/ntdll-unix/build.sh` compiles `loader_ios.c` (first object) without a
missing-header error.

3.4 **Small libs, in this order, each through its existing script with the
shims on PATH:** `build/gnutls-ios/build.sh` (prefix `toolchains/gnutls-ios`
headers; the four `.a` are tracked, compare them with `cmp` as a sanity
check), `build/freetype-ios/build.sh` (clone freetype `VER-2-13-3` into
`research/freetype` first), `build/ffmpeg/build.sh`, `build/rppairing-ios/
build.sh` (cargo needs the iOS target and `CC_aarch64_apple_ios`/`AR_...`
pointing at the shims). Gate 3.4: each produces its `.a`; `file` says arm64.

3.5 **`libwineserver.a` base.** Answer from the maintainer if available.
Fallback: compile every `wine/server/*.c` with the `CC_FLAGS` in
`build/wineserver/build.sh` (minus the files in its `PATCHED_FILES` list,
which it recompiles itself), `ar rcs app/Madeira/libwineserver.a`, then run
`build/wineserver/build.sh`. Expect the symbol-rename step ("objcopy" in the
script's comments) to need `llvm-objcopy`. Gate 3.5: link-test later at 5.5;
until then `nm` shows `wineserver_main` defined once.

3.6 `build/ntdll-unix/build.sh`, `build/win32u-unix/build.sh`,
`build/fex-ios/build.sh` (CMake, `CMAKE_SYSTEM_NAME iOS` -> use the Darwin
form as in 3.2), `build/dxmt-ios/build.sh` (needs `dxmt_command` metallib
header: see 5.1), `build/stage-licenses.sh`,
`build/madeira-d3d12/fetch-converter.sh` (verifies the tracked converter).
Gate 3.6: every output of the table in section 0 exists and is arm64 Mach-O.

## 5. Phase 4: resources that need Apple's compilers

5.1 From the official release IPA of the same version (download from the
GitHub release; ~140 MB): `Payload/Madeira.app/default.metallib`,
`Assets.car`, `AppIcon*.png`, `prefix-template.tar.gz`. For DXMT's embedded
`dxmt_command` metallib, carve it from `Payload/Madeira.app/Madeira` (search
for the `MTLB` magic; the header's length field gives the size) and write
`build/dxmt-ios/shader-headers/dxmt_command.h` with `xxd -n dxmt_command -i`.
Gate 5.1: `file default.metallib` is "Metal library".
If shaders or icons are being edited, use section 7 instead.

## 6. Phase 5: the app build driver (`tools/ios-cross/build.sh` + `gen_ninja.py`)

5.2 `gen_ninja.py` reads `project.pbxproj` and emits `build.ninja`: the Swift
file list and build settings per target (`app/Madeira`, `MadeiraJITHelper`),
C/ObjC/ObjC++ sources with their flags, resource list, link inputs. Compile
Swift in one `swiftc` invocation per target: `-module-name Madeira -target
arm64-apple-ios17.0 -sdk $SDK -swift-version 5 -Onone -g -D DEBUG
-import-objc-header app/Madeira/Madeira-Bridging-Header.h -enable-testing`
(drop what the pbxproj does not set). Compile C family with the shim clang.
5.3 Link: `swiftc ... -use-ld=lld` (or `ld64.lld`) with the `-framework` list
and the `.a` files and `-Wl,-ObjC`/`-all_load`/`force_load` exactly as the
pbxproj `OTHER_LDFLAGS` says; add `-Xlinker -rpath -Xlinker @executable_path/Frameworks`.
5.4 Bundle: `Info.plist` with `$(VARIABLE)` substitution (bundle id
`com.willfaust.madeora`, version from `MARKETING_VERSION`), resources per the
pbxproj Resources phase (arm64ec-windows, aarch64-windows, i386-windows,
d3d12, nls, legal, licenses, prefix-template.tar.gz, madeira-jit.js, cacert.pem,
`hello_x86.elf`, the `.shortcut`), `Frameworks/StikJIT.framework` from the
xcframework slice `ios-arm64`, `PlugIns/MadeiraJITHelper.appex`. Re-implement
the three script phases ("Sign bundled dylibs", licence staleness check, "Bundle
Wine Mono": skip Mono like release builds).
5.5 Sign + package: `ldid -Sapp/Madeira/Madeira.entitlements Madeira.app/Madeira`
(and the appex with its own entitlements), `zip -r` a `Payload/` folder -> IPA.
5.6 **Parity gate:** compare against the official IPA of the same version:
`unzip -l` file lists (differences only in files the build is expected to
change), `plutil`-equivalent Info.plist diff (use Python `plistlib`),
`ldid -e` entitlements equal. Then the user sideloads it; if the app opens and
reaches "Ready to play", record that in `STATE.md`. A crash at launch is
debugged from the device log the user pastes.

## 7. Hybrid fallback: free macOS runner only for Apple compilers

If a step needs `metal`/`actool` (edited shaders or icons) and the user has a
public GitHub repo: workflow on `macos-latest` (macOS 26, free in public
repos, 6 h jobs) that runs `xcrun metal`/`metallib`/`actool` on the files in
the repo and uploads `default.metallib`, `Assets.car`, `dxmt_command.h`
as artifacts. Tiny and cheap; the rest of the build stays on the PC. Do not
build the whole app there: see `tools/madeira-fix/README.md`, "Why not build
the whole app in GitHub Actions".

## 8. Known risks (tell the user, do not hide them)

- Swift 6.4 on Linux must import Xcode 26's SDK `.swiftinterface` files and
  SwiftUI's newest APIs; gate 2.2 tests the basics but a specific file
  (`GlassSkin.swift`) may need a workaround. Worst case: compile that file's
  features out with `#if` under a documented local patch.
- Several Wine/FEX `configure`/CMake steps assume a real macOS host and may
  need cache variables or small script patches (keep them in
  `tools/ios-cross/patches/` with a note why).
- No Apple tool checks the result. The only oracle is the official IPA's
  structure and the user's iPhone.
- Effort: expect several sessions, most of it phases 3.2-3.6 and 5.x. Each
  gate that passes is saved in `STATE.md`; never repeat finished phases.
- The Apple SDK licence issue in section 1.1 stays the user's decision.
