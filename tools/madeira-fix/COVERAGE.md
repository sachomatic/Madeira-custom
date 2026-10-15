# What GitHub Actions (and the local tool) can fix

Both run the same `madeira-fix.sh`, so they cover the same things: **Windows
binaries inside the IPA**. Anything compiled into the app executable is out of
reach without a full iOS build (see `tools/ios-cross/PLAYBOOK.md`).

| Fix from `FIXES.md` | Covered | How |
|---|---|---|
| Steam games without launch entry 0 (PEAK, Persona 3 Reload) | Yes | Rebuilt Dock host with the launch-entry fix and per-game entries. Still set `env.MADEIRA_DOCK_LAUNCH_OPTIONS` in `madeira.cfg`. |
| Motorslice missing `tbs.dll` | Yes | Wine's own `tbs.dll` added to `arm64ec-windows/`. |
| Another missing Wine DLL | Yes | `--modules "tbs dcomp ..."` (workflow input `modules`). |
| Visual C++ runtime DLLs | Local tool only | Microsoft files: `--vcruntime DIR` with your own copies. |
| Touch-control wheel buttons, Size slider | No | Swift, in the app executable. Patch kept in `tools/ios-cross/patches/madeira/`. |
| Frostpunk geometry-shader crash | No | DXMT converter, inside the app's iOS library. Patch in `dist/frostpunk-dxmt/`. |
| Touch controller buttons in keyboard-and-mouse mode | No | Not implemented; would be Swift. |
| PEAK killed by iOS (memory) | Settings, not code | `swap-mb`, `vram-mb`, lower texture quality (`FIXES.md`). |
| Slime Rancher ignores the XInput pad | Unresolved | Cause probably in the app. |

A new release can break a patch if it changes the code the patch touches; the
build then stops and names the patch.
