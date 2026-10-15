# madeira-fix: fixed Madeira IPAs without a Mac

Takes **any official Madeira release** and swaps in rebuilt Windows-side files.
It costs nothing and needs no Mac. It reads the release's version from the IPA,
asks GitHub which `wine` and `madeira-dock` commits that release pins, builds
exactly those commits with llvm-mingw (plus the patches in `patches/`), and
writes `<ipa>-fixed.ipa`. Run it again for the next release; nothing is
hard-coded to 0.1.3.

## What it fixes

| Problem (see `FIXES.md`) | How |
|---|---|
| Steam games without launch entry 0 never start (PEAK, Persona 3 Reload) | Dock host rebuilt with the launch-entry fix and per-game entries: `env.MADEIRA_DOCK_LAUNCH_OPTIONS = 3527290:6, 2161700:1` in `madeira.cfg` (details in `dist/dockhost-launch-option/README.md`). Releases whose Dock pin already has the fix skip that patch. |
| Motorslice: `tbs.dll` missing | Wine's own `tbs.dll` (ARM64EC) added to `arm64ec-windows/`. Any other Wine module can be added with `--modules "tbs dcomp ..."`. |

What it **cannot** fix: anything in the app itself (Swift, the touch-control
changes, the iOS libraries, DXMT's shader converter such as the Frostpunk
patch). Those are compiled into the app's executable and need a Mac build.

## Use it on your PC (Windows + WSL2 Ubuntu)

One time, in an administrator PowerShell:

```powershell
wsl -d Ubuntu -u root -- apt-get install -y git curl python3 make gcc bison flex xz-utils
```

Then, from this folder:

```powershell
.\Fix-Madeira.ps1 -Version 0.1.3                 # downloads the official IPA, fixes it
.\Fix-Madeira.ps1 -Ipa C:\path\Madeira-0.1.4.ipa  # or fix one you already have
```

The first run downloads llvm-mingw (82 MB, checksum-checked) and the two source
trees (a few hundred MB) into `~/.cache/madeira-fix` inside WSL; later runs
reuse them. The Wine build takes 5 to 15 minutes. Then sideload the `-fixed.ipa`
over the installed app with SideStore, AltStore or Sideloadly: games, saves and
the prefix are kept.

On Linux or inside WSL: `./madeira-fix.sh --version 0.1.3` (`--help` lists the options).

## Use it in the cloud (GitHub Actions)

1. Make a **public** GitHub repository (standard runners are free there) and put
   the contents of this folder in its root, including `.github/`.
2. Actions tab, **Fix Madeira IPA**, **Run workflow**: a version (blank = the
   latest release), then download the IPA from the run's artifacts.
3. It also checks daily for a new upstream release and, when there is one,
   builds it and publishes a release named `fixed-<version>` in your repository.
   Delete the `schedule:` block in the workflow to turn that off.

The workflow only runs this same script on a Linux runner. It is a
convenience for building from a phone or without WSL.

## When a new release breaks a patch

`patches/<submodule>/*.patch` are applied to the pinned commit with `git apply`.
A patch already in the tree is skipped. One that no longer applies stops the
build with its name: refresh it against the new commit (the Dock patches are plain
diffs of `src/` and `tests/`) or delete it if upstream took the change. Patches
for Wine would go in `patches/wine/`.

## Why not build the whole app in GitHub Actions

It was looked into (2026-10-13). A macOS runner is free in a public repository
(`macos-latest` is macOS 26 on Apple silicon, jobs up to 6 hours), and the
upstream repository has no workflow of its own. But the iOS part cannot be
rebuilt from a clean checkout yet, on any Mac:

- `build/wineserver/build.sh` only swaps patched objects into a prebuilt
  `libwineserver.a` that is not in the repository;
- `ntdll-unix`, `win32u-unix` and the wineserver need a macOS-configured Wine
  tree (`wine/build-macos`) whose configure command is not written down;
- DXMT needs LLVM built for iOS (`toolchains/llvm-ios-build`, a multi-hour
  build whose recipe `docs/BUILDING.md` marks UNVERIFIED);
- the Visual C++ runtime DLLs the Xcode project expects are Microsoft files.

A workflow for that would be a long trial-and-error project, so this tool
takes the route that works today. If upstream adds those missing inputs or a
CI of its own, it becomes a few lines.

## Files

| | |
|---|---|
| `madeira-fix.sh` | the whole tool (Linux/WSL) |
| `Fix-Madeira.ps1` | Windows front end for WSL |
| `patch_ipa.py` | reads an IPA's version and adds/replaces files in it (any file, any folder) |
| `patches/` | the patch queue, per submodule |
| `.github/workflows/fix-ipa.yml` | the cloud version |
